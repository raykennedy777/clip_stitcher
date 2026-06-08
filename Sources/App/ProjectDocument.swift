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

/// Export progress and outcome. Runtime-only — not persisted.
enum ExportStatus: Equatable {
    case idle
    case running(Double)
    case done(warnings: [String])
    case failed(String)
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

    /// Set by the UI from the environment so mutations register undo and mark the
    /// document dirty. May be nil very early in a window's lifetime.
    var undoManager: UndoManager?

    /// Resolved source URLs, keyed by clip id. Populated on import and lazily when
    /// resolving a saved clip's bookmark.
    private var urlCache: [Clip.ID: URL] = [:]

    /// Per-clip frame index, built on first cut-editor open and reused for the rest
    /// of the session (and by the export engine) — ADR-0006's "cached" intent.
    private var frameIndexCache: [Clip.ID: FrameIndex] = [:]

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

    func deleteClip(id: Clip.ID) {
        var p = project
        p.clips.removeAll { $0.id == id }
        if p.targetClipID == id {
            p.targetClipID = p.clips.first?.id
        }
        commit(p)
        importStates[id] = nil
        urlCache[id] = nil
        frameIndexCache[id] = nil
    }

    func clearAll() {
        var p = project
        p.clips.removeAll()
        p.targetClipID = nil
        commit(p)
        importStates.removeAll()
        urlCache.removeAll()
        frameIndexCache.removeAll()
    }

    /// Rebinds a clip to a new source file (after its original went missing), clears
    /// stale metadata + cached index, and re-imports.
    func relink(id: Clip.ID, to newURL: URL) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        p.clips[i].bookmark = (try? newURL.bookmarkData()) ?? Data()
        p.clips[i].displayName = newURL.lastPathComponent
        p.clips[i].video = nil
        p.clips[i].audio = nil
        p.clips[i].duration = nil
        p.clips[i].frameCount = nil
        urlCache[id] = newURL
        frameIndexCache[id] = nil
        importStates[id] = .probing
        commit(p)
        Task { await importClip(id: id, url: newURL) }
    }

    func setTarget(id: Clip.ID) {
        var p = project
        p.targetClipID = id
        commit(p)
    }

    func move(id: Clip.ID, by delta: Int) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard project.clips.indices.contains(j) else { return }
        var p = project
        p.clips.swapAt(i, j)
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

    /// Runs a Milestone 2 export to `destination`: each clip is cut at the **exact** in/out
    /// frame the user chose (ADR-0009) — the keyframe-bounded middle is stream-copied and
    /// only the partial-GOP head/tail edges are re-encoded — with the audio rebuilt so it
    /// stays aligned at the joins. Progress and outcome are published in `exportStatus` for
    /// the Output view. No snapping, so there are no "cut snapped" warnings.
    @MainActor
    func export(to destination: URL) async {
        exportStatus = .running(0)
        do {
            var items: [ExportItem] = []
            var warnings: [String] = []
            for (i, clip) in project.clips.enumerated() {
                guard let url = url(for: clip) else {
                    throw ExportError.cutFailed("Source file not found for “\(clip.displayName)”.")
                }
                let index = try await frameIndex(for: clip)
                let copySafe = CopySafeBoundaryDetector.copySafeFlags(
                    keyframeFlags: index.keyframeFlags, dts: index.dts)
                let segments = BoundaryReencodePlanner.plan(
                    copySafeFlags: copySafe, frameCount: index.count,
                    inFrame: clip.inPoint, outFrame: clip.outPoint)
                guard !segments.isEmpty else { throw ExportError.invalidPlan }
                // Re-encode args matched to the source so the edges concat cleanly with the
                // copied middle (ADR-0009).
                let encoder = BoundaryReencodeEngine.reencodeVideoArgs(
                    codec: clip.video?.codec,
                    profile: clip.video?.profile,
                    pixelFormat: clip.video?.pixelFormat,
                    fieldOrder: clip.video?.fieldOrder)
                // The audio is re-encoded over the same kept range as the video, in source
                // presentation time. A `nil` point means that end is the clip boundary (no
                // cut there), so the audio runs to the file's start/end too.
                let audioStart = clip.inPoint.map { index.pts[$0] }
                let audioEnd = clip.outPoint.map { index.pts[$0] }
                items.append(ExportItem(source: url, codec: clip.video?.codec,
                                        segments: segments, index: index, encoder: encoder,
                                        audioStart: audioStart, audioEnd: audioEnd))
            }
            // MPEG-2 in an MP4 container muxes with a non-monotonic-DTS warning at joins
            // and mislabels the audio; TS is the right container for this footage (ADR-0008).
            if project.output.container == .mp4 && items.contains(where: { $0.codec == "mpeg2video" }) {
                warnings.append("MPEG-2 video sits awkwardly in MP4 (possible glitch at joins) — choose the TS container for this footage.")
            }
            try await ExportEngine.export(items: items, settings: project.output, to: destination) { p in
                Task { @MainActor in
                    if case .running = self.exportStatus { self.exportStatus = .running(p) }
                }
            }
            exportStatus = .done(warnings: warnings)
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
