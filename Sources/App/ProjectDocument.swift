import SwiftUI
import UniformTypeIdentifiers

enum ImportState: Equatable {
    case probing
    case indexing
    case ready
    case sourceMissing
    case failed(String)
}

enum ExportStatus: Equatable {
    case idle
    case running(fraction: Double, eta: String?)
    case done(warnings: [String])
    case failed(String)
    case cancelled(detail: String?)
}

@MainActor
final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = VidProject

    nonisolated static var readableContentTypes: [UTType] { [.clipStitcherProject] }

    static let noVideoTrackFailure = "No video track"

    @Published var project: VidProject
    @Published var importStates: [Clip.ID: ImportState] = [:]
    @Published var copyShares: [Clip.ID: ExportPlanner.CopyShare] = [:]
    @Published var exportStatus: ExportStatus = .idle
    @Published var doctorSuggestions: [Clip.ID] = []
    @Published var inOutResets: [Clip.ID] = []
    @Published var exportCancelRequested = false
    private var exportTask: Task<Void, Never>? = nil
    private var exportStartedAt = Date()
    private var exportETA = ExportProgress.ETAEstimator()

    var undoManager: UndoManager?

    private var urlCache: [Clip.ID: URL] = [:]

    private var frameIndexCache: [Clip.ID: FrameIndex] = [:]

    private var containerStartCache: [Clip.ID: Double] = [:]

    private var lastViewedFrames: [Clip.ID: Int] = [:]

    private let importThrottle = AsyncSemaphore(limit: 3)

    private var didResolveSources = false

    init() {
        var project = VidProject()
        project.output.container = AppSettings.defaultContainer()
        self.project = project
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.project = try JSONDecoder().decode(VidProject.self, from: data)
    }

    func snapshot(contentType: UTType) throws -> VidProject {
        project
    }

    func fileWrapper(snapshot: VidProject, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
    }

    private func commit(_ new: VidProject) {
        let old = project
        project = new
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.commit(old)
        }
        refreshCopyShares()
    }

    func refreshCopyShares() {
        var shares: [Clip.ID: ExportPlanner.CopyShare] = [:]
        for clip in project.clips {
            guard let index = frameIndexCache[clip.id] else { continue }
            shares[clip.id] = ExportPlanner.copyShare(
                for: clip, target: project.targetClip, settings: project.output, index: index,
                containerStart: containerStartCache[clip.id] ?? 0)
        }
        if shares != copyShares { copyShares = shares }
    }

    func hasTruncatedEnding(_ clip: Clip) -> Bool {
        guard let index = frameIndexCache[clip.id] else { return false }
        let containerStart = containerStartCache[clip.id] ?? 0
        return ExportPlanner.truncatedEndingTrim(
            zones: clip.damageZones, windowStart: nil,
            fileEnd: ExportPlanner.fileEnd(index: index, frameRate: clip.video?.frameRate,
                                           containerStart: containerStart),
            reachesFileEnd: true,
            frameInterval: ExportPlanner.frameDuration(clip.video?.frameRate)) != nil
    }

    func addFiles(_ urls: [URL], at index: Int? = nil) {
        var p = project
        var pending: [(Clip.ID, URL)] = []
        var newClips: [Clip] = []
        for url in urls {
            let bookmark = (try? url.bookmarkData()) ?? Data()
            let clip = Clip(bookmark: bookmark, displayName: url.lastPathComponent)
            newClips.append(clip)
            pending.append((clip.id, url))
            urlCache[clip.id] = url
            importStates[clip.id] = .probing
        }
        let insertAt = min(max(0, index ?? p.clips.count), p.clips.count)
        p.clips.insert(contentsOf: newClips, at: insertAt)
        if p.targetClipID == nil {
            p.targetClipID = p.clips.first?.id
        }
        commit(p)
        for (id, url) in pending {
            Task { await importClip(id: id, url: url) }
        }
    }

    @discardableResult
    func duplicateClip(id: Clip.ID) -> Clip.ID? {
        duplicateClips(ids: [id]).first
    }

    @discardableResult
    func duplicateClips(ids: Set<Clip.ID>) -> [Clip.ID] {
        let selected = Set(project.clips.enumerated()
            .filter { ids.contains($0.element.id) }.map(\.offset))
        guard let insertAt = BatchSelection.duplicateInsertionIndex(selected: selected) else {
            return []
        }
        let originals = selected.sorted().map { project.clips[$0] }
        let copies: [Clip] = originals.map { original in
            var copy = original
            copy.id = UUID()
            return copy
        }
        var p = project
        p.clips.insert(contentsOf: copies, at: insertAt)
        commit(p)
        for (original, copy) in zip(originals, copies) {
            adoptRuntimeState(of: original.id, for: copy)
        }
        refreshCopyShares()
        return copies.map(\.id)
    }

    private func adoptRuntimeState(of originalID: Clip.ID, for copy: Clip) {
        urlCache[copy.id] = urlCache[originalID]
        frameIndexCache[copy.id] = frameIndexCache[originalID]
        containerStartCache[copy.id] = containerStartCache[originalID]
        lastViewedFrames[copy.id] = lastViewedFrames[originalID]
        switch importStates[originalID] {
        case .probing, .indexing, nil:
            importStates[copy.id] = .probing
            if let url = url(for: copy) {
                Task { await importClip(id: copy.id, url: url) }
            } else {
                importStates[copy.id] = .sourceMissing
            }
        case let state?:
            importStates[copy.id] = state
        }
    }

    func deleteClips(ids: Set<Clip.ID>) {
        var p = project
        p.clips.removeAll { ids.contains($0.id) }
        guard p.clips.count != project.clips.count else { return }
        if let target = p.targetClipID, ids.contains(target) {
            p.targetClipID = p.clips.first?.id
        }
        commit(p)
        for id in ids {
            importStates[id] = nil
            urlCache[id] = nil
            frameIndexCache[id] = nil
            containerStartCache[id] = nil
            lastViewedFrames[id] = nil
        }
        doctorSuggestions.removeAll { ids.contains($0) }
        inOutResets.removeAll { ids.contains($0) }
    }

    func clearAll() {
        var p = project
        p.clips.removeAll()
        p.targetClipID = nil
        commit(p)
        importStates.removeAll()
        urlCache.removeAll()
        frameIndexCache.removeAll()
        containerStartCache.removeAll()
        lastViewedFrames.removeAll()
        doctorSuggestions.removeAll()
        inOutResets.removeAll()
    }

    func relink(ids: Set<Clip.ID>, to newURL: URL) {
        let bookmark = (try? newURL.bookmarkData()) ?? Data()
        var p = project
        var touched: [Clip.ID] = []
        for i in p.clips.indices where ids.contains(p.clips[i].id) {
            p.clips[i].bookmark = bookmark
            p.clips[i].displayName = newURL.lastPathComponent
            p.clips[i].video = nil
            p.clips[i].audio = nil
            p.clips[i].audioTracks = nil
            p.clips[i].duration = nil
            p.clips[i].frameCount = nil
            p.clips[i].fieldCoded = nil
            p.clips[i].damageZones = nil
            touched.append(p.clips[i].id)
        }
        guard !touched.isEmpty else { return }
        for id in touched {
            urlCache[id] = newURL
            frameIndexCache[id] = nil
            containerStartCache[id] = nil
            lastViewedFrames[id] = nil
            importStates[id] = .probing
        }
        doctorSuggestions.removeAll { touched.contains($0) }
        inOutResets.removeAll { touched.contains($0) }
        commit(p)
        for id in touched {
            Task { await importClip(id: id, url: newURL) }
        }
    }

    nonisolated static func validatedInOut(inPoint: Int?, outPoint: Int?, frameCount: Int)
        -> (inPoint: Int?, outPoint: Int?, didReset: Bool) {
        let range = 0..<frameCount
        let inOK = inPoint.map(range.contains) ?? true
        let outOK = outPoint.map(range.contains) ?? true
        if inOK && outOK { return (inPoint, outPoint, false) }
        return (nil, nil, true)
    }

    nonisolated static func snappedInOut(inPoint: Int?, outPoint: Int?, leadingCounts: [Int?])
        -> (inPoint: Int?, outPoint: Int?, didChange: Bool) {
        let snappedIn = inPoint.map { CopyCutSnapper.snapInPoint($0, leadingCounts: leadingCounts) }
        let snappedOut = outPoint.map { CopyCutSnapper.snapOutPoint($0, leadingCounts: leadingCounts) }
        if snappedIn == .some(nil) || snappedOut == .some(nil) { return (nil, nil, true) }
        let newIn = snappedIn.flatMap { $0 }
        let newOut = snappedOut.flatMap { $0 }
        if let newIn, let newOut, newIn > newOut { return (nil, nil, true) }
        return (newIn, newOut, newIn != inPoint || newOut != outPoint)
    }

    @MainActor
    func reconcileInOut(id: Clip.ID, index: FrameIndex) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[i]
        let validated = Self.validatedInOut(
            inPoint: clip.inPoint, outPoint: clip.outPoint, frameCount: index.count)
        var (newIn, newOut) = (validated.inPoint, validated.outPoint)
        var changed = validated.didReset
        if FieldCodedSupport.requiresCopyOnlyCuts(fieldCoded: clip.fieldCoded, codec: clip.video?.codec) {
            let snapped = Self.snappedInOut(
                inPoint: newIn, outPoint: newOut,
                leadingCounts: CopySafeBoundaryDetector.leadingPictureCounts(
                    keyframeFlags: index.keyframeFlags, dts: index.dts))
            (newIn, newOut) = (snapped.inPoint, snapped.outPoint)
            changed = changed || snapped.didChange
        }
        guard changed else { return }
        var p = project
        p.clips[i].inPoint = newIn
        p.clips[i].outPoint = newOut
        commit(p)
        if !inOutResets.contains(id) { inOutResets.append(id) }
    }

    enum ReopenResolution: Equatable { case missing, reimport, ready }

    nonisolated static func reopenResolution(resolved: Bool, hasVideo: Bool) -> ReopenResolution {
        guard resolved else { return .missing }
        return hasVideo ? .ready : .reimport
    }

    func dismissInOutReset(_ id: Clip.ID) {
        inOutResets.removeAll { $0 == id }
    }

    func setTarget(id: Clip.ID) {
        var p = project
        p.targetClipID = id
        commit(p)
    }

    func move(ids: Set<Clip.ID>, by delta: Int) {
        let selected = Set(project.clips.enumerated()
            .filter { ids.contains($0.element.id) }.map(\.offset))
        guard let order = BatchSelection.movedOrder(
            count: project.clips.count, selected: selected, delta: delta) else { return }
        var p = project
        p.clips = order.map { project.clips[$0] }
        commit(p)
    }

    func setOutput(_ output: OutputSettings) {
        var p = project
        p.output = output
        commit(p)
    }

    func setInOut(id: Clip.ID, inPoint: Int?, outPoint: Int?) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        p.clips[i].inPoint = inPoint
        p.clips[i].outPoint = outPoint
        commit(p)
    }

    func splitClip(id: Clip.ID, ranges: [SplitRanges.Range]) {
        guard ranges.count > 1,
              let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let original = project.clips[i]
        let pieces: [Clip] = ranges.enumerated().map { n, range in
            var piece = original
            if n > 0 { piece.id = UUID() }
            piece.inPoint = range.inPoint
            piece.outPoint = range.outPoint
            piece.displayName = "\(original.displayName) (\(n + 1))"
            return piece
        }
        var p = project
        p.clips.replaceSubrange(i...i, with: pieces)
        commit(p)
        for piece in pieces.dropFirst() {
            adoptRuntimeState(of: id, for: piece)
        }
        refreshCopyShares()
    }

    func setAudioSelections(ids: Set<Clip.ID>, selections: [AudioTrackSlot]?) {
        var p = project
        var changed = false
        for i in p.clips.indices where ids.contains(p.clips[i].id) {
            p.clips[i].audioSelections = selections
            if let monitored = p.clips[i].monitoredAudioTrack {
                let count = p.clips[i].resolvedAudioSelections.count
                p.clips[i].monitoredAudioTrack = count == 0 ? nil : min(monitored, count - 1)
            }
            changed = true
        }
        guard changed else { return }
        commit(p)
    }

    func setMonitoredOutputTrack(_ slot: Int) {
        var p = project
        p.monitoredOutputTrack = slot
        commit(p)
    }

    func setMonitoredAudioTrack(id: Clip.ID, slot: Int) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        p.clips[i].monitoredAudioTrack = slot
        commit(p)
    }

    func setExternalAudio(ids: Set<Clip.ID>, template: Clip.ID, slot: Int, url: URL) async {
        let probe = try? await MediaProbe.probe(url: url)
        guard let i = project.clips.firstIndex(where: { $0.id == template }) else { return }
        var selections = project.clips[i].resolvedAudioSelections
        guard slot < selections.count else { return }
        selections[slot] = .external(
            bookmark: (try? url.bookmarkData()) ?? Data(),
            name: url.lastPathComponent,
            streamIndex: 0,
            tracks: probe?.audioTracks,
            duration: probe?.duration
        )
        setAudioSelections(ids: ids, selections: selections)
    }

    func lastViewedFrame(for id: Clip.ID) -> Int? {
        lastViewedFrames[id]
    }

    func setLastViewedFrame(_ frame: Int, for id: Clip.ID) {
        lastViewedFrames[id] = frame
    }

    func url(for clip: Clip) -> URL? {
        resolveSource(for: clip, refreshIfStale: false)
    }

    @discardableResult
    private func resolveSource(for clip: Clip, refreshIfStale: Bool) -> URL? {
        if let cached = urlCache[clip.id] { return cached }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: clip.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        urlCache[clip.id] = resolved
        if isStale, refreshIfStale,
           let fresh = try? resolved.bookmarkData(),
           let i = project.clips.firstIndex(where: { $0.id == clip.id }) {
            var p = project
            p.clips[i].bookmark = fresh
            p.clips[i].displayName = resolved.lastPathComponent
            commit(p)
        }
        return resolved
    }

    func resolveSourcesIfNeeded() {
        guard !didResolveSources else { return }
        didResolveSources = true
        for clip in project.clips where importStates[clip.id] == nil {
            let url = resolveSource(for: clip, refreshIfStale: true)
            switch Self.reopenResolution(resolved: url != nil, hasVideo: clip.video != nil) {
            case .missing:
                importStates[clip.id] = .sourceMissing
            case .reimport:
                importStates[clip.id] = .probing
                if let url {
                    let id = clip.id
                    Task { await importClip(id: id, url: url) }
                }
            case .ready:
                importStates[clip.id] = .ready
            }
        }
        for clip in project.clips where importStates[clip.id] == .ready {
            Task { @MainActor in
                do { try await importThrottle.acquire() } catch { return }
                defer { Task { await importThrottle.release() } }
                if (try? await frameIndex(for: clip)) != nil {
                    if let url = url(for: clip), containerStartCache[clip.id] == nil {
                        containerStartCache[clip.id] = await MediaProbe.containerStartTime(url: url)
                    }
                    refreshCopyShares()
                }
            }
        }
    }

    func frameIndex(for clip: Clip) async throws -> FrameIndex {
        if let cached = frameIndexCache[clip.id] { return cached }
        guard let url = url(for: clip) else {
            throw FFError.indexFailed("Source file not found.")
        }
        let built = try await FrameIndexer.buildIndex(url: url)
        frameIndexCache[clip.id] = built
        reconcileInOut(id: clip.id, index: built)
        return built
    }

    @MainActor
    func containerStart(for clip: Clip) async -> Double {
        if let cached = containerStartCache[clip.id] { return cached }
        guard let url = url(for: clip) else { return 0 }
        let value = await MediaProbe.containerStartTime(url: url)
        containerStartCache[clip.id] = value
        return value
    }

    @MainActor
    func doctorInputs(for clip: Clip) async throws -> (url: URL, index: FrameIndex, containerStart: Double) {
        guard let url = url(for: clip) else {
            throw FFError.indexFailed("Source file not found.")
        }
        let index = try await frameIndex(for: clip)
        let containerStart: Double
        if let cached = containerStartCache[clip.id] {
            containerStart = cached
        } else {
            containerStart = await MediaProbe.containerStartTime(url: url)
            containerStartCache[clip.id] = containerStart
        }
        return (url, index, containerStart)
    }

    @MainActor
    func dismissDoctorSuggestion(_ id: Clip.ID) {
        doctorSuggestions.removeAll { $0 == id }
    }

    nonisolated static func clipNotReadyReason(for clip: Clip, state: ImportState?) -> String? {
        switch state {
        case .ready, .none:
            return nil
        case .probing, .indexing:
            return "“\(clip.displayName)” is still being analysed — wait for it to finish, then export."
        case .failed(let message):
            return "“\(clip.displayName)” couldn’t be imported (\(message)). Remove or relink it, then export."
        case .sourceMissing:
            return "The source for “\(clip.displayName)” is missing. Relink it, then export."
        }
    }

    nonisolated static func exportDisabledReason(clips: [Clip], states: [Clip.ID: ImportState]) -> String? {
        let analysing = clips.filter {
            switch states[$0.id] {
            case .probing, .indexing: return true
            default: return false
            }
        }.count
        if analysing > 0 {
            return analysing == 1 ? "Analysing 1 clip…" : "Analysing \(analysing) clips…"
        }
        let unresolved = clips.filter {
            switch states[$0.id] {
            case .failed, .sourceMissing: return true
            default: return false
            }
        }.count
        if unresolved > 0 {
            return unresolved == 1
                ? "One clip couldn’t be imported — remove or relink it to export."
                : "\(unresolved) clips couldn’t be imported — remove or relink them to export."
        }
        return nil
    }

    @MainActor
    func startExport(to destination: URL) {
        exportTask = Task { await export(to: destination) }
    }

    @MainActor
    func cancelExport() {
        exportCancelRequested = true
        exportTask?.cancel()
    }

    nonisolated static func cancelDetail(finished: Int, total: Int) -> String? {
        guard finished > 0, total > 1 else { return nil }
        return "\(finished) of \(total) files were finished."
    }

    @MainActor
    func export(to destination: URL) async {
        exportStatus = .running(fraction: 0, eta: nil)
        exportCancelRequested = false
        exportStartedAt = Date()
        exportETA = ExportProgress.ETAEstimator()
        do {
            var items: [ExportItem] = []
            var warnings: [String] = []
            let cutOnly = project.output.mode == .separate
                && project.output.rendering == .cutOnly
            for clip in project.clips {
                if let reason = Self.clipNotReadyReason(for: clip, state: importStates[clip.id]) {
                    throw ExportError.clipNotReady(reason)
                }
                guard let url = url(for: clip) else {
                    throw ExportError.cutFailed("Source file not found for “\(clip.displayName)”.")
                }
                let index = try await frameIndex(for: clip)
                let clip = project.clips.first(where: { $0.id == clip.id }) ?? clip
                let containerStart: Double
                if let cached = containerStartCache[clip.id] {
                    containerStart = cached
                } else {
                    containerStart = await MediaProbe.containerStartTime(url: url)
                    containerStartCache[clip.id] = containerStart
                }
                let audioSources: [ExportEngine.AudioSource?]
                do {
                    audioSources = try AudioSourceResolver.resolveSources(
                        for: clip, missingExternal: .throwError)
                } catch let missing as AudioSourceResolver.MissingExternalFile {
                    throw ExportError.cutFailed("External audio file “\(missing.name)” (track \(missing.slot + 1) of “\(clip.displayName)”) was not found.")
                }
                for (slot, trackSlot) in clip.resolvedAudioSelections.enumerated() {
                    if case .external(_, let name, _, _, _) = trackSlot.selection,
                       let gap = clip.externalAudioMismatch(slot: slot), abs(gap) >= 1.0 {
                        let direction = gap < 0 ? "shorter — silence fills the rest" : "longer — the extra is unused"
                        warnings.append("“\(name)” is \(String(format: "%.1f", abs(gap))) s \(direction) (track \(slot + 1) of “\(clip.displayName)”).")
                    }
                }

                var item = try ExportPlanner.planItem(
                    for: ExportPlanner.ClipInput(clip: clip, url: url, index: index,
                                                 containerStart: containerStart,
                                                 audioSources: audioSources,
                                                 audioMixFilters: AudioSourceResolver.resolveMixFilters(for: clip)),
                    target: project.targetClip, settings: project.output)
                if let conform = item.conform,
                   let note = ConformEngine.assumedColorWarning(
                       clipName: clip.displayName,
                       source: conform.sourceVideo, target: conform.targetVideo) {
                    warnings.append(note)
                }
                if project.output.type != .audioOnly,
                   let note = ExportPlanner.repairReport(
                       clipName: clip.displayName, zones: clip.damageZones,
                       windowStart: item.audioStart, windowEnd: item.audioEnd,
                       trimEnd: item.truncatedEndingTrim,
                       frameInterval: ExportPlanner.frameDuration(clip.video?.frameRate)) {
                    warnings.append(note)
                }
                if cutOnly {
                    let own = AudioSourceResolver.resolveOwnTracks(
                        clip: clip, type: project.output.type, container: project.output.container)
                    item.ownTracks = own.tracks
                    for fb in own.fallbacks {
                        let dest = project.output.type == .audioOnly
                            ? "an audio file" : "the \(project.output.container.fileExtension.uppercased()) container"
                        warnings.append("\(fb.codec.uppercased()) audio can’t go in \(dest) — track \(fb.slot + 1) of “\(clip.displayName)” exports AAC instead.")
                    }
                }
                items.append(item)
            }
            if let note = ExportPlanner.reorderDepthWarning(items: items, settings: project.output) {
                warnings.append(note)
            }
            if project.output.container == .mp4 && items.contains(where: { $0.codec == "mpeg2video" }) {
                warnings.append("MPEG-2 video sits awkwardly in MP4 (possible glitch at joins) — choose the TS container for this footage.")
            }
            let targetAudioCodec = cutOnly ? nil : project.targetClip?.audio?.codec
            let audio = project.output.type == .audioOnly
                ? AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: targetAudioCodec)
                : AudioCodecPolicy.resolveAudioCodec(targetCodec: targetAudioCodec, container: project.output.container)
            if audio.fellBack, let wanted = targetAudioCodec {
                let dest = project.output.type == .audioOnly
                    ? "an audio file" : "the \(project.output.container.fileExtension.uppercased()) container"
                warnings.append("\(wanted.uppercased()) audio can’t go in \(dest) — exporting AAC audio instead.")
            }
            var tracks = AudioSourceResolver.resolveOutputTracks(target: project.targetClip, clips: project.clips)
            if project.output.type == .audioOnly { tracks = Array(tracks.prefix(1)) }
            try await ExportEngine.export(items: items, settings: project.output,
                                          audioCodec: audio.encoder, tracks: tracks, to: destination) { p in
                Task { @MainActor in
                    guard case .running(let shown, _) = self.exportStatus, p >= shown else { return }
                    let remaining = self.exportETA.update(
                        fraction: p, elapsed: Date().timeIntervalSince(self.exportStartedAt))
                    self.exportStatus = .running(
                        fraction: p, eta: ExportProgress.etaLabel(remaining: remaining, fraction: p))
                }
            }
            exportStatus = .done(warnings: warnings)
        } catch ExportError.cancelled(let finished, let total) {
            exportStatus = .cancelled(detail: Self.cancelDetail(finished: finished, total: total))
        } catch is CancellationError {
            exportStatus = .cancelled(detail: nil)
        } catch {
            exportStatus = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func importClip(id: Clip.ID, url: URL) async {
        do { try await importThrottle.acquire() } catch { return }
        defer { Task { await importThrottle.release() } }
        do {
            let probe = try await MediaProbe.probe(url: url)
            guard probe.video != nil else {
                importStates[id] = .failed(Self.noVideoTrackFailure)
                return
            }
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].video = probe.video
                p.clips[i].audio = probe.audio
                p.clips[i].audioTracks = probe.audioTracks
                p.clips[i].duration = probe.duration
                commit(p)
            }
            importStates[id] = .indexing

            let scan = try await FrameIndexer.scanAllStreams(url: url)
            let index = scan.index
            frameIndexCache[id] = index
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].frameCount = index.count
                p.clips[i].fieldCoded = FieldCodingDetector.isFieldCoded(
                    packetPts: index.pts,
                    frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])
                commit(p)
            }
            reconcileInOut(id: id, index: index)
            let containerStart = probe.containerStart
            containerStartCache[id] = containerStart
            let zones = await DamageDetector.detectZones(
                url: url, scan: scan, containerStart: containerStart)
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].damageZones = zones
                commit(p)
                let clip = p.clips[i]
                if zones.contains(where: \.affectsVideo),
                   clip.fieldCoded != true || ClipDoctorEngine.canRepairFieldCoded(codec: clip.video?.codec) {
                    doctorSuggestions.append(id)
                }
            }
            importStates[id] = .ready
            refreshCopyShares()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            importStates[id] = .failed(message)
        }
    }
}
