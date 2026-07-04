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

/// The document backing one ClipStitcher project. A reference type so async import
/// work (ffprobe + frame indexing) can mutate published state safely.
///
/// Persisted state lives in `project` (a Codable `VidProject`). Everything else
/// here (import states, resolved URLs) is runtime-only.
@MainActor
final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = VidProject

    nonisolated static var readableContentTypes: [UTType] { [.clipStitcherProject] }

    /// The import failure recorded for a source with no video track (issue #83). Import
    /// rejects audio-only files with this exact message; the Source view keys the Clip
    /// Doctor "video sources only" explanation off it, so the string can't drift.
    static let noVideoTrackFailure = "No video track"

    @Published var project: VidProject
    @Published var importStates: [Clip.ID: ImportState] = [:]
    /// Per-clip copy/re-encode split, recomputed from the cached frame indexes whenever
    /// the project changes (issue #15) — the Source rows and the Output view's dominance
    /// warning read this. Pure planner arithmetic, no media I/O; a clip stays absent
    /// until its index is built.
    @Published var copyShares: [Clip.ID: ExportPlanner.CopyShare] = [:]
    /// Runtime-only export progress/outcome, surfaced by the Output view.
    @Published var exportStatus: ExportStatus = .idle
    /// Clips whose import-time damage detection just finished with repairable damage
    /// (issue #55) — the Source view shows a one-time, dismissible banner suggesting
    /// Clip Doctor for the first still-valid entry. Runtime-only; audio-only gaps are
    /// never enqueued (every export silence-fills them), but field-coded clips now are
    /// (issue #54's damage-to-EOF path). A FIFO queue so a burst of imports surfaces one
    /// banner at a time, never a modal pile-up.
    @Published var doctorSuggestions: [Clip.ID] = []
    /// Clips whose stored in/out points were reset to whole-clip because a relink's
    /// re-import landed a shorter file the old points no longer fit (issue #74). The
    /// Source view surfaces a one-time, dismissible notice — the reset is never silent.
    /// Runtime-only; a FIFO queue matching `doctorSuggestions`.
    @Published var inOutResets: [Clip.ID] = []
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

    /// Per-clip container start_time, cached alongside the frame index: the base of
    /// every damage-zone time, which the planner needs to map zones onto frames
    /// (issue #47) — including the synchronous copy-share refresh, which can't probe.
    private var containerStartCache: [Clip.ID: Double] = [:]

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
        // Every project mutation — in/out points, target, output settings, splits, undo —
        // funnels through here, so this is the one place the copy/re-encode shares stay
        // current (issue #15). Pure arithmetic over cached indexes; no media I/O.
        refreshCopyShares()
    }

    /// Recomputes every clip's copy/re-encode split from the cached frame indexes
    /// (issue #15). Clips whose index isn't built yet are skipped — they gain a share
    /// when their import/index task finishes.
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
        // The copies' indexes were adopted *after* the commit-time refresh ran.
        refreshCopyShares()
        return copies.map(\.id)
    }

    /// Hands a fresh copy the original's runtime state: they point at the same file,
    /// so the copy shares the resolved URL and frame index instead of re-resolving
    /// and re-indexing.
    private func adoptRuntimeState(of originalID: Clip.ID, for copy: Clip) {
        urlCache[copy.id] = urlCache[originalID]
        frameIndexCache[copy.id] = frameIndexCache[originalID]
        containerStartCache[copy.id] = containerStartCache[originalID]
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
        // Re-detection on the new source will re-suggest if it's damaged; drop any
        // stale suggestion for these clips meanwhile (issue #55). Likewise clear any
        // prior in/out-reset notice — the re-import re-evaluates against the new file
        // and re-surfaces one if the (kept) points still don't fit (issue #74).
        doctorSuggestions.removeAll { touched.contains($0) }
        inOutResets.removeAll { touched.contains($0) }
        commit(p)
        for id in touched {
            Task { await importClip(id: id, url: newURL) }
        }
    }

    /// Validates a clip's stored in/out points against a (re-imported) frame count
    /// (issue #74). Valid positions are `0..<frameCount`; `outPoint` is an inclusive
    /// frame. Both still in range → kept unchanged (the common same-file-moved relink).
    /// Either out of range → both reset to nil (whole clip), since a stale point outrunning
    /// a now-shorter index would trap the export planner's frame lookup. `didReset` tells
    /// the caller a reset happened so it's surfaced, never silent.
    nonisolated static func validatedInOut(inPoint: Int?, outPoint: Int?, frameCount: Int)
        -> (inPoint: Int?, outPoint: Int?, didReset: Bool) {
        let range = 0..<frameCount
        let inOK = inPoint.map(range.contains) ?? true
        let outOK = outPoint.map(range.contains) ?? true
        if inOK && outOK { return (inPoint, outPoint, false) }
        return (nil, nil, true)
    }

    /// Reconciles a clip's stored in/out against a freshly-built frame count (issue #74) —
    /// the single altitude every fresh-index path funnels through: import, relink,
    /// reopen's lazy rebuild, and the export-time rebuild. A source replaced on disk with a
    /// shorter file while the app was closed lands here on the next index build; stale points
    /// reset to whole-clip and queue the notice, instead of trapping the planner as a bare
    /// `invalidPlan`. A no-op when the points still fit (the common case) or are already nil
    /// (fresh imports). Mutates `project`/`inOutResets`, so it hops to the main actor.
    @MainActor
    func reconcileInOut(id: Clip.ID, frameCount: Int) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let validated = Self.validatedInOut(
            inPoint: project.clips[i].inPoint, outPoint: project.clips[i].outPoint,
            frameCount: frameCount)
        guard validated.didReset else { return }
        var p = project
        p.clips[i].inPoint = validated.inPoint
        p.clips[i].outPoint = validated.outPoint
        commit(p)
        if !inOutResets.contains(id) { inOutResets.append(id) }
    }

    /// The post-reopen resolution for one clip (issue #78 follow-up), factored out so it's
    /// testable without real bookmarks. An unresolvable source is `.missing`; a resolvable
    /// clip whose probed `video` never persisted — autosaved mid-probe, so it can never
    /// export (`videoTreatment` throws `clipNotReady`) yet would look ready — must be
    /// `.reimport`ed (re-probe + re-index); otherwise it's `.ready`.
    enum ReopenResolution: Equatable { case missing, reimport, ready }

    nonisolated static func reopenResolution(resolved: Bool, hasVideo: Bool) -> ReopenResolution {
        guard resolved else { return .missing }
        return hasVideo ? .ready : .reimport
    }

    /// Drops a clip from the in/out-reset notice queue (issue #74) — the user dismissed
    /// its notice, so it shouldn't surface again.
    func dismissInOutReset(_ id: Clip.ID) {
        inOutResets.removeAll { $0 == id }
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
        // The later pieces' indexes were adopted *after* the commit-time refresh ran.
        refreshCopyShares()
    }

    // MARK: - Audio tracks (ADR-0014)

    /// Replaces the audio track slots of every clip in `ids` in one undo step;
    /// `nil` restores the default (all of the clip's own streams in container
    /// order, each at the Original mix). This is the Audio Settings sheet's
    /// same-source fan-out (issue #12) — it covers the slot assignments only: each
    /// clip's monitored-track choice is untouched beyond clamping it into the new list.
    func setAudioSelections(ids: Set<Clip.ID>, selections: [AudioTrackSlot]?) {
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
            let url = resolveSource(for: clip, refreshIfStale: true)
            switch Self.reopenResolution(resolved: url != nil, hasVideo: clip.video != nil) {
            case .missing:
                importStates[clip.id] = .sourceMissing
            case .reimport:
                // A clip autosaved mid-probe persisted with `video == nil` (issue #78
                // follow-up): marking it `.ready` from bookmark resolvability alone would
                // wrongly enable export on a clip that can never encode. Route it through
                // the import path — it re-probes, rebuilds the index, and sets the state.
                importStates[clip.id] = .probing
                if let url {
                    let id = clip.id
                    Task { await importClip(id: id, url: url) }
                }
            case .ready:
                importStates[clip.id] = .ready
            }
        }
        // A reopened project has no runtime indexes yet; build them in the background
        // (throttled like import) so the copy/re-encode shares appear without waiting
        // for an export or a cut-editor open (issue #15). The container start rides
        // along — a damaged clip's share needs it to map zones (issue #47).
        for clip in project.clips where importStates[clip.id] == .ready {
            Task { @MainActor in
                await importThrottle.acquire()
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

    /// The clip's frame index, built on first request and cached for the session.
    func frameIndex(for clip: Clip) async throws -> FrameIndex {
        if let cached = frameIndexCache[clip.id] { return cached }
        guard let url = url(for: clip) else {
            throw FFError.indexFailed("Source file not found.")
        }
        let built = try await FrameIndexer.buildIndex(url: url)
        frameIndexCache[clip.id] = built
        // A freshly-built index is the moment to reconcile stored in/out against the real
        // file (issue #74): reopen's lazy rebuild and the export-time rebuild both land
        // here, not just import — a source shortened on disk while closed resets to
        // whole-clip and surfaces the notice, rather than trapping the planner.
        reconcileInOut(id: clip.id, frameCount: built.count)
        return built
    }

    // MARK: - Clip Doctor (issue #53, ADR-0021)

    /// The inputs Clip Doctor needs for one clip, reusing the import-time caches: the
    /// resolved source URL, the cached (or just-built) frame index, and the cached (or
    /// just-probed) container start_time — the same `frameIndexCache`/`containerStartCache`
    /// the export reads, so an already-imported clip needs no re-index or re-probe. Throws
    /// when the source can't be resolved.
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

    /// Drops a clip from the Clip Doctor suggestion queue (issue #55) — the user
    /// dismissed its banner or opened its repair sheet, so it shouldn't suggest again
    /// for this detection.
    @MainActor
    func dismissDoctorSuggestion(_ id: Clip.ID) {
        doctorSuggestions.removeAll { $0 == id }
    }

    // MARK: - Export readiness gate (issue #78)

    /// Why a single clip can't be exported yet, or `nil` when it's ready. `export()`
    /// throws this (as `ExportError.clipNotReady`) for the first unready clip, so a
    /// probing/indexing/failed clip never reaches encoder selection with `video == nil`.
    /// A `nil` state means "ready" — the Source row treats it the same (unimported clips
    /// carry no runtime state) and the planner's own guard still refuses a truly-unprobed
    /// clip. Pure over the passed state so the gate is testable without real media.
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

    /// The Output view's export-disabled reason (issue #78), or `nil` when export can
    /// proceed. Clips still being analysed take priority — they resolve on their own, so
    /// the reason names the count ("Analysing 2 clips…"); otherwise a failed or
    /// source-missing clip needs the user to remove or relink it (its row shows the
    /// specific error). Pure over the passed clips/states so it's testable and can't
    /// disagree with `clipNotReadyReason`.
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
                // The button gates on import state (issue #78), but the keyboard/automation
                // path reaches here regardless — refuse an unready clip with a specific,
                // user-readable reason before any planning, so a probing clip never routes
                // into smart render with `video == nil` (and never as a bare `invalidPlan`).
                if let reason = Self.clipNotReadyReason(for: clip, state: importStates[clip.id]) {
                    throw ExportError.clipNotReady(reason)
                }
                guard let url = url(for: clip) else {
                    throw ExportError.cutFailed("Source file not found for “\(clip.displayName)”.")
                }
                let index = try await frameIndex(for: clip)
                // Building the index above may have reset stale in/out against the real
                // file (issue #74) — re-read the clip so planning sees the reconciled
                // points, not this loop's now-stale copy. The plan is built below, after
                // this, so a reset-before-plan can't corrupt an in-flight plan.
                let clip = project.clips.first(where: { $0.id == clip.id }) ?? clip
                let containerStart: Double
                if let cached = containerStartCache[clip.id] {
                    containerStart = cached
                } else {
                    containerStart = await MediaProbe.containerStartTime(url: url)
                    containerStartCache[clip.id] = containerStart
                }
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
                for (slot, trackSlot) in clip.resolvedAudioSelections.enumerated() {
                    if case .external(_, let name, _, _, _) = trackSlot.selection,
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
                                                 audioSources: audioSources,
                                                 audioMixFilters: AudioSourceResolver.resolveMixFilters(for: clip)),
                    target: project.targetClip, settings: project.output)
                // A conform toward a color-tagged target may have to *assume* the source's
                // color standard when the source carries no tags (issue #35); the assumption
                // is surfaced rather than silent so a wrong-looking result is explicable.
                if let conform = item.conform,
                   let note = ConformEngine.assumedColorWarning(
                       clipName: clip.displayName,
                       source: conform.sourceVideo, target: conform.targetVideo) {
                    warnings.append(note)
                }
                // Always repair, never silently (issues #47/#48): a clip's damage
                // zones in the kept window come out repaired on both video paths —
                // smart-render (repaired re-encode segments) and conform (the chain's
                // select-before-fps) — say so.
                if project.output.type != .audioOnly,
                   let note = ExportPlanner.repairReport(
                       clipName: clip.displayName, zones: clip.damageZones,
                       windowStart: item.audioStart, windowEnd: item.audioEnd) {
                    warnings.append(note)
                }
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

    // MARK: - Import pipeline

    @MainActor
    private func importClip(id: Clip.ID, url: URL) async {
        await importThrottle.acquire()
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
                // No per-codec container override anymore: MKV is the unconditional
                // default (issue #10) and carries all three codecs by stream-copy, so
                // the user's container choice — including the default — is never touched.
                commit(p)
            }
            importStates[id] = .indexing

            // The full per-frame index, not just the packet count — both demux the whole
            // file once, and having the index cached at import is what lets the copy/
            // re-encode share show before any export or cut-editor open (issue #15). The
            // count comes off the index so the row, the cut-editor, and the planner can
            // never disagree about frame numbering. The read covers all streams (issue
            // #45): the same pass feeds the damage detector's demux-anomaly stage.
            let scan = try await FrameIndexer.scanAllStreams(url: url)
            let index = scan.index
            frameIndexCache[id] = index
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].frameCount = index.count
                // Field-coded check (issue #46): measured packet cadence vs the probed
                // display rate — the index's timestamps are already in hand here.
                p.clips[i].fieldCoded = FieldCodingDetector.isFieldCoded(
                    packetPts: index.pts,
                    frameRates: [probe.video?.frameRate, probe.videoCodecFrameRate])
                commit(p)
            }
            // Now the new frame count is known, drop any stored in/out that no longer fits
            // (issue #74) — the shared reconciliation every fresh-index path funnels through
            // (relink to a shorter file leaves stale points that would trap the planner).
            // Fresh imports carry nil in/out, so this is a no-op for them.
            reconcileInOut(id: id, frameCount: index.count)
            // Damage detection (issue #45): cluster the demux anomalies, then a few
            // bounded seek-anchored confirm decodes around them — zero decodes on a
            // clean file, never a from-start full decode. Failures degrade to "none
            // found"; a damaged source must still import.
            let containerStart = await MediaProbe.containerStartTime(url: url)
            containerStartCache[id] = containerStart
            let zones = await DamageDetector.detectZones(
                url: url, scan: scan, containerStart: containerStart)
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].damageZones = zones
                commit(p)
                // Suggest Clip Doctor for a freshly damaged, repairable clip (issue
                // #55): any video-affecting zone (audio-only gaps are already
                // silence-filled by every export, issue #44). Field-coded H.264 sources
                // are included — they take the damage-to-EOF re-encode (issue #54); a
                // non-H.264 field-coded clip can't be repaired (mixed-codec tail) and
                // isn't suggested (issue #57).
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
