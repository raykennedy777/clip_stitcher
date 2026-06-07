import SwiftUI
import UniformTypeIdentifiers

/// Per-clip import progress. Runtime-only — not persisted in the document.
enum ImportState: Equatable {
    case probing
    case indexing
    case ready
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

    /// Set by the UI from the environment so mutations register undo and mark the
    /// document dirty. May be nil very early in a window's lifetime.
    var undoManager: UndoManager?

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

    func addFiles(_ urls: [URL]) {
        var p = project
        var pending: [(Clip.ID, URL)] = []
        for url in urls {
            let bookmark = (try? url.bookmarkData()) ?? Data()
            let clip = Clip(bookmark: bookmark, displayName: url.lastPathComponent)
            p.clips.append(clip)
            pending.append((clip.id, url))
            importStates[clip.id] = .probing
        }
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
    }

    func clearAll() {
        var p = project
        p.clips.removeAll()
        p.targetClipID = nil
        commit(p)
        importStates.removeAll()
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

    // MARK: - Import pipeline

    @MainActor
    private func importClip(id: Clip.ID, url: URL) async {
        do {
            let probe = try await MediaProbe.probe(url: url)
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                var p = project
                p.clips[i].video = probe.video
                p.clips[i].audio = probe.audio
                p.clips[i].duration = probe.duration
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
