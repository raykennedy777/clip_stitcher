import SwiftUI
import UniformTypeIdentifiers

/// Per-clip import progress. Runtime-only — not persisted in the document.
enum ImportState: Equatable {
    case probing
    case indexing
    case ready
    case sourceMissing
    case failed(String)
}

/// Export progress and outcome. Runtime-only — not persisted. While running, `eta`
/// is the damped "About X remaining" label (issue #9), `nil` until there's enough
/// signal to estimate.
enum ExportStatus: Equatable {
    case idle
    case running(fraction: Double, eta: String?)
    case done(warnings: [String])
    case failed(String)
    /// The user cancelled (issue #32) — neutral, nothing went wrong. `detail` reports
    /// kept `.separate` files ("3 of 5 files were finished."), nil when there's
    /// nothing to add.
    case cancelled(detail: String?)
}

/// The document backing one VidConform project. A reference type so async import
/// work (ffprobe + frame indexing) can mutate published state safely.
///
/// Persisted state lives in `project` (a Codable `VidProject`). Everything else
/// here (import states, resolved URLs) is runtime-only.
final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = VidProject

    static var readableContentTypes: [UTType] { [.vidConformProject] }

    @Published var project: VidProject
    @Published var importStates: [Clip.ID: ImportState] = [:]
    /// Runtime-only export progress/outcome, surfaced by the Output view.
    @Published var exportStatus: ExportStatus = .idle
    /// True once the user confirmed a cancel (issue #32) — disables the cancel button
    /// while the asynchronous termination plays out. Reset when an export starts.
    @Published var exportCancelRequested = false
    /// The running export, kept so "Cancel Export…" can cancel it (issue #32) —
    /// `ProcessRunner` terminates the live ffmpeg on Task cancellation.
    private var exportTask: Task<Void, Never>? = nil
    /// ETA bookkeeping for the running export (issue #9), reset on each `export`.
    private var exportStartedAt = Date()
    private var exportETA = ExportProgress.ETAEstimator()

    /// Set by the UI from the environment so mutations register undo and mark the
    /// document dirty. May be nil very early in a window's lifetime.
    var undoManager: UndoManager?

    /// Resolved source URLs, keyed by clip id. Populated on import and lazily when
    /// resolving a saved clip's bookmark.
    private var urlCache: [Clip.ID: URL] = [:]

    /// Per-clip frame index, built on first cut-editor open and reused for the rest
    /// of the session (and by the export engine) — ADR-0006's "cached" intent.
    private var frameIndexCache: [Clip.ID: FrameIndex] = [:]

    /// Where each clip's cut-editor was last closed, so reopening resumes there.
    /// Runtime-only view state — never an undoable document edit.
    private var lastViewedFrames: [Clip.ID: Int] = [:]

    /// Bounds how many clips probe/scan their source at once, so bulk-importing many
    /// large files doesn't launch a process storm.
    private let importThrottle = AsyncSemaphore(limit: 3)

    /// Guards the one-time source-resolution pass run after a project is opened.
    private var didResolveSources = false

    init() {
        self.project = VidProject()
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

    // MARK: - Mutation

    /// Apply a new project value, registering an undo so the document is marked edited.
    private func commit(_ new: VidProject) {
        let old = project
        project = new
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.commit(old)
        }
    }

    /// Imports `urls`, inserting them at `index` (clamped) or appending when nil.
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

    /// Inserts a copy of a clip directly after the original: a new row with its own
    /// identity but the same source file, probed properties, and in/out selection.
    /// Returns the new clip's id so the UI can select it.
    @discardableResult
    func duplicateClip(id: Clip.ID) -> Clip.ID? {
        duplicateClips(ids: [id]).first
    }

    /// Copies every selected clip, inserting the copies as one contiguous run
    /// directly below the bottommost selected clip, copies in timeline order
    /// (issue #12). One undo step reverses the whole batch. Returns the new ids in
    /// timeline order so the UI can select them.
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
        return copies.map(\.id)
    }

    /// Hands a fresh copy the original's runtime state: they point at the same file,
    /// so the copy shares the resolved URL and frame index instead of re-resolving
    /// and re-indexing.
    private func adoptRuntimeState(of originalID: Clip.ID, for copy: Clip) {
        urlCache[copy.id] = urlCache[originalID]
        frameIndexCache[copy.id] = frameIndexCache[originalID]
        lastViewedFrames[copy.id] = lastViewedFrames[originalID]
        switch importStates[originalID] {
        case .probing, .indexing, nil:
            // The original's in-flight import only fills the original's row — give
            // the copy its own pass.
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

    /// Deletes every selected clip in one undo step (issue #12).
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
            lastViewedFrames[id] = nil
        }
    }

    func clearAll() {
        var p = project
        p.clips.removeAll()
        p.targetClipID = nil
        commit(p)
        importStates.removeAll()
        urlCache.removeAll()
        frameIndexCache.removeAll()
        lastViewedFrames.removeAll()
    }

    /// Rebinds every selected clip to a new source file in one undo step (issue #12 —
    /// the gate guarantees they all pointed at the same missing file), clears stale
    /// metadata + cached indexes, and re-imports each.
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
            touched.append(p.clips[i].id)
        }
        guard !touched.isEmpty else { return }
        for id in touched {
            urlCache[id] = newURL
            frameIndexCache[id] = nil
            lastViewedFrames[id] = nil
            importStates[id] = .probing
        }
        commit(p)
        for id in touched {
            Task { await importClip(id: id, url: newURL) }
        }
    }

    func setTarget(id: Clip.ID) {
        var p = project
        p.targetClipID = id
        commit(p)
    }

    /// Moves the selected clips one step up (-1) or down (+1) as one contiguous
    /// block, relative order preserved (issue #12) — for a single clip this is the
    /// familiar adjacent swap. One undo step.
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

    /// Replaces a clip with one clip per split range in one undo step (issue #20,
    /// ADR-0017). The first range keeps the original clip's identity — a split
    /// target clip stays the target and its caches stay warm — while later ranges
    /// are copies with fresh ids. Names get " (1)", " (2)", … suffixes in range
    /// order so the rows are tellable apart in the Source view.
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
    }

    // MARK: - Audio tracks (ADR-0014)

    /// Replaces the audio track slots of every clip in `ids` in one undo step;
    /// `nil` restores the default (all of the clip's own streams in container
    /// order). This is the Audio Settings sheet's same-source fan-out (issue #12) —
    /// it covers the slot assignments only: each clip's monitored-track choice is
    /// untouched beyond clamping it into the new list.
    func setAudioSelections(ids: Set<Clip.ID>, selections: [AudioTrackSelection]?) {
        var p = project
        var changed = false
        for i in p.clips.indices where ids.contains(p.clips[i].id) {
            p.clips[i].audioSelections = selections
            // Keep the monitored slot inside the new list.
            if let monitored = p.clips[i].monitoredAudioTrack {
                let count = p.clips[i].resolvedAudioSelections.count
                p.clips[i].monitoredAudioTrack = count == 0 ? nil : min(monitored, count - 1)
            }
            changed = true
        }
        guard changed else { return }
        commit(p)
    }

    /// Stores the Preview's monitored output-track choice (issue #8) — the track
    /// heard when the assembled timeline plays, saved with the project.
    func setMonitoredOutputTrack(_ slot: Int) {
        var p = project
        p.monitoredOutputTrack = slot
        commit(p)
    }

    /// Stores the cut-editor's monitored-track choice for a clip.
    func setMonitoredAudioTrack(id: Clip.ID, slot: Int) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        p.clips[i].monitoredAudioTrack = slot
        commit(p)
    }

    /// Points an audio slot at an external file (audio-only or another video) for
    /// every clip in `ids`, in one undo step: probes all of the file's audio
    /// streams — for the per-stream picker, naming, formats, and the
    /// length-mismatch notice (ADR-0014) — then commits the selection on its first
    /// audio stream. The settings sheet switches streams from there. The slot list
    /// is read from `template` — the sheet's displayed clip — and the updated list
    /// lands on all of them (issue #12).
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

    /// The frame the clip's cut-editor was last closed on this session, if any.
    func lastViewedFrame(for id: Clip.ID) -> Int? {
        lastViewedFrames[id]
    }

    func setLastViewedFrame(_ frame: Int, for id: Clip.ID) {
        lastViewedFrames[id] = frame
    }

    /// Resolves a clip's source file URL from its bookmark (cached). Returns nil if
    /// the source can no longer be found.
    func url(for clip: Clip) -> URL? {
        resolveSource(for: clip, refreshIfStale: false)
    }

    /// Resolves a clip's source URL from cache or its bookmark. When `refreshIfStale`
    /// is set and the OS reports the bookmark stale (the file moved but was still
    /// found), the stored bookmark is regenerated and persisted so it survives the
    /// next save.
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
            // The bookmark followed a rename/move — reflect the file's current name.
            p.clips[i].displayName = resolved.lastPathComponent
            commit(p)
        }
        return resolved
    }

    /// One-time pass after a project is opened: mark clips whose source can no longer
    /// be resolved as `.sourceMissing` (so the row shows a relink affordance) and
    /// refresh any moved-but-found bookmarks.
    func resolveSourcesIfNeeded() {
        guard !didResolveSources else { return }
        didResolveSources = true
        for clip in project.clips where importStates[clip.id] == nil {
            importStates[clip.id] = resolveSource(for: clip, refreshIfStale: true) == nil
                ? .sourceMissing
                : .ready
        }
    }

    /// The clip's frame index, built on first request and cached for the session.
    func frameIndex(for clip: Clip) async throws -> FrameIndex {
        if let cached = frameIndexCache[clip.id] { return cached }
        guard let url = url(for: clip) else {
            throw FFError.indexFailed("Source file not found.")
        }
        let built = try await FrameIndexer.buildIndex(url: url)
        frameIndexCache[clip.id] = built
        return built
    }

    // MARK: - Export (Milestone 2: frame-exact boundary re-encode)

    /// Runs a Milestone 2 export to `destination` — the chosen file in `.connect` mode,
    /// the chosen folder in `.separate` mode (issue #30): each clip is cut at the **exact** in/out
    /// frame the user chose (ADR-0009) — the keyframe-bounded middle is stream-copied and
    /// only the partial-GOP head/tail edges are re-encoded — with the audio rebuilt so it
    /// stays aligned at the joins. Progress and outcome are published in `exportStatus` for
    /// the Output view. No snapping, so there are no "cut snapped" warnings.
    /// Starts an export and keeps its Task so "Cancel Export…" can cancel it
    /// (issue #32). The UI goes through this, not `export(to:)` directly.
    @MainActor
    func startExport(to destination: URL) {
        exportTask = Task { await export(to: destination) }
    }

    /// Cancels the running export: `ProcessRunner` terminates the live ffmpeg, the
    /// engine discards the partial file (keeping finished separate-mode files), and
    /// the status lands on `.cancelled` — never `.failed` (issue #32).
    @MainActor
    func cancelExport() {
        exportCancelRequested = true
        exportTask?.cancel()
    }

    /// The cancelled-status detail line: in separate mode, files finished before the
    /// cancel stay on disk and the user should know how many (issue #32). Nothing to
    /// add when none were (or it's connect mode's single file: total 1).
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
            // Cut-only (ADR-0018): separate mode's "just accurately cut" rendering
            // choice — the verdict ignores the target (planner severs it) and each
            // clip's audio is its own tracks at their own codecs (per-item below).
            let cutOnly = project.output.mode == .separate
                && project.output.rendering == .cutOnly
            for clip in project.clips {
                guard let url = url(for: clip) else {
                    throw ExportError.cutFailed("Source file not found for “\(clip.displayName)”.")
                }
                let index = try await frameIndex(for: clip)
                let containerStart = await MediaProbe.containerStartTime(url: url)
                // Each output track's leg comes from the clip's selected source for it:
                // one of its own streams, an external file, or silence (ADR-0014). The
                // shared resolver throws on a missing external file — the export refuses
                // to silently drop a selected track (the preview degrades instead).
                // MissingExternalFile is the resolver's only error; map it to the
                // user-facing export failure.
                let audioSources: [ExportEngine.AudioSource?]
                do {
                    audioSources = try AudioSourceResolver.resolveSources(
                        for: clip, missingExternal: .throwError)
                } catch let missing as AudioSourceResolver.MissingExternalFile {
                    throw ExportError.cutFailed("External audio file “\(missing.name)” (track \(missing.slot + 1) of “\(clip.displayName)”) was not found.")
                }
                // Pad/trim is by design; a gap of 1 s or more gets a notice (ADR-0014).
                for (slot, selection) in clip.resolvedAudioSelections.enumerated() {
                    if case .external(_, let name, _, _, _) = selection,
                       let gap = clip.externalAudioMismatch(slot: slot), abs(gap) >= 1.0 {
                        let direction = gap < 0 ? "shorter — silence fills the rest" : "longer — the extra is unused"
                        warnings.append("“\(name)” is \(String(format: "%.1f", abs(gap))) s \(direction) (track \(slot + 1) of “\(clip.displayName)”).")
                    }
                }

                // The planning itself — the smart-render-vs-conform verdict, the
                // boundary re-encode segment plan, and the kept window — is pure and
                // lives in ExportPlanner (ADR-0009 / ADR-0011). The output settings
                // carry the rendering choice into the verdict (ADR-0018).
                var item = try ExportPlanner.planItem(
                    for: ExportPlanner.ClipInput(clip: clip, url: url, index: index,
                                                 containerStart: containerStart,
                                                 audioSources: audioSources),
                    target: project.targetClip, settings: project.output)
                if cutOnly {
                    // Each clip's output carries exactly its own tracks, each encoded
                    // to its own source codec — AAC where the container declines one,
                    // with a warning naming the clip and track (ADR-0018).
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
            // MPEG-2 in an MP4 container muxes with a non-monotonic-DTS warning at joins
            // and mislabels the audio; TS is the right container for this footage (ADR-0008).
            if project.output.container == .mp4 && items.contains(where: { $0.codec == "mpeg2video" }) {
                warnings.append("MPEG-2 video sits awkwardly in MP4 (possible glitch at joins) — choose the TS container for this footage.")
            }
            // The rebuilt audio conforms to the target clip's codec (ADR-0010). For an
            // audio-only output the codec goes in its own elementary file, so there is no
            // video container to fit; otherwise it must fit the chosen container (AAC fallback).
            // In cut-only the target's codec governs nothing — every track carries its
            // own encoder (above); the export-wide codec is only the AAC default for
            // a track with none (a silence slot).
            let targetAudioCodec = cutOnly ? nil : project.targetClip?.audio?.codec
            let audio = project.output.type == .audioOnly
                ? AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: targetAudioCodec)
                : AudioCodecPolicy.resolveAudioCodec(targetCodec: targetAudioCodec, container: project.output.container)
            if audio.fellBack, let wanted = targetAudioCodec {
                let dest = project.output.type == .audioOnly
                    ? "an audio file" : "the \(project.output.container.fileExtension.uppercased()) container"
                warnings.append("\(wanted.uppercased()) audio can’t go in \(dest) — exporting AAC audio instead.")
            }
            // Output track count = the richest clip's; formats/tags target-first
            // (ADR-0014). An audio-only export goes to a single elementary stream, which
            // can only carry one track — keep track 1.
            var tracks = AudioSourceResolver.resolveOutputTracks(target: project.targetClip, clips: project.clips)
            if project.output.type == .audioOnly { tracks = Array(tracks.prefix(1)) }
            try await ExportEngine.export(items: items, settings: project.output,
                                          audioCodec: audio.encoder, tracks: tracks, to: destination) { p in
                // Progress arrives mid-run from a background queue; hop to the main
                // actor and keep the bar monotonic (within-run smoothing and the
                // per-phase steps can interleave a hair out of order).
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
            // Cancelled before the engine took over (probe/index phase) — same outcome,
            // no files were being written yet.
            exportStatus = .cancelled(detail: nil)
        } catch {
            exportStatus = .failed(error.localizedDescription)
        }
    }

    /// The container that best fits a source codec for a stream-copy export: MPEG-2
    /// broadcast video belongs in TS; H.264/HEVC default to MP4 (ADR-0008).
    static func defaultContainer(forCodec codec: String) -> Container {
        codec == "mpeg2video" ? .ts : .mp4
    }

    // MARK: - Import pipeline

    @MainActor
    private func importClip(id: Clip.ID, url: URL) async {
        await importThrottle.acquire()
        defer { Task { await importThrottle.release() } }
        do {
            let probe = try await MediaProbe.probe(url: url)
            guard probe.video != nil else {
                importStates[id] = .failed("No video track")
                return
            }
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].video = probe.video
                p.clips[i].audio = probe.audio
                p.clips[i].audioTracks = probe.audioTracks
                p.clips[i].duration = probe.duration
                // Default the container to suit the first clip's codec (broadcast MPEG-2
                // belongs in TS, not MP4). Only on the first clip, so it never overrides a
                // container the user later chose.
                if p.clips.count == 1, let codec = probe.video?.codec {
                    p.output.container = Self.defaultContainer(forCodec: codec)
                }
                commit(p)
            }
            importStates[id] = .indexing

            let count = try await FrameIndexer.frameCount(url: url)
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].frameCount = count
                commit(p)
            }
            importStates[id] = .ready
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            importStates[id] = .failed(message)
        }
    }
}
