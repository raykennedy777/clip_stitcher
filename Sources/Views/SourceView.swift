import SwiftUI
import UniformTypeIdentifiers

struct SourceView: View {
    @ObservedObject var document: ProjectDocument
    @EnvironmentObject private var cutEditor: CutEditorPresenter
    @State private var selection: Clip.ID?
    @State private var importing = false
    @State private var relinking = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            clipList
            Divider()
            actionPanel
        }
        .navigationTitle("Source")
        .onAppear { document.resolveSourcesIfNeeded() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: Self.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                document.addFiles(urls)
            }
        }
        .fileImporter(
            isPresented: $relinking,
            allowedContentTypes: Self.contentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first, let id = selection {
                document.relink(id: id, to: url)
            }
        }
    }

    // MARK: - Clip list

    @ViewBuilder
    private var clipList: some View {
        if document.project.clips.isEmpty {
            ContentUnavailableView(
                "No Clips",
                systemImage: "film.stack",
                description: Text("Add a video file — or drag one here — to begin building the timeline.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(Array(document.project.clips.enumerated()), id: \.element.id) { index, clip in
                    ClipRowView(
                        position: index + 1,
                        clip: clip,
                        role: role(for: clip),
                        state: document.importStates[clip.id] ?? .ready
                    )
                    .tag(clip.id)
                    // Native NSTableView double-click → open the cut-editor, without
                    // disturbing the List's single-click selection + highlight.
                    .background(ListDoubleClickAction { row in
                        let clips = document.project.clips
                        guard clips.indices.contains(row) else { return }
                        let clip = clips[row]
                        selection = clip.id
                        openCutEditor(for: clip)
                    })
                }
                .onInsert(of: [.fileURL]) { index, providers in
                    loadVideoURLs(from: providers) { urls in
                        if !urls.isEmpty { document.addFiles(urls, at: index) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onKeyPress(.return) {
                if let id = selection, let clip = document.project.clips.first(where: { $0.id == id }) {
                    openCutEditor(for: clip)
                    return .handled
                }
                return .ignored
            }
            // ⌘↑ / ⌘↓ reorder the selected clip. Plain arrows are left to the List
            // for selection navigation (we ignore them here).
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                move(by: press.key == .upArrow ? -1 : 1)
                return .handled
            }
        }
    }

    private func role(for clip: Clip) -> ClipRole {
        if clip.id == document.project.targetClipID { return .target }
        guard let targetID = document.project.targetClipID,
              let target = document.project.clips.first(where: { $0.id == targetID }),
              clip.video != nil else {
            return .unknown
        }
        return MatchEvaluator.matches(clip, target: target) ? .smartRender : .reEncode
    }

    // MARK: - Action panel

    private var actionPanel: some View {
        VStack(spacing: 8) {
            action("Add File", systemImage: "plus") { importing = true }

            Divider().padding(.vertical, 6)

            action("Move Up", systemImage: "arrow.up", enabled: canMove(by: -1)) { move(by: -1) }
            action("Move Down", systemImage: "arrow.down", enabled: canMove(by: 1)) { move(by: 1) }
            action("Delete", systemImage: "trash", enabled: selection != nil) { deleteSelected() }
            action("Clear", systemImage: "xmark.bin", enabled: !document.project.clips.isEmpty) {
                document.clearAll()
                selection = nil
            }

            Divider().padding(.vertical, 6)

            action("Set as Target Clip", systemImage: "target", enabled: canSetTarget) {
                if let id = selection { document.setTarget(id: id) }
            }
            action("Relink…", systemImage: "link", enabled: canRelink) { relinking = true }

            Spacer()
        }
        .padding()
        .frame(width: 200)
    }

    private func action(_ title: String, systemImage: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }

    // MARK: - Actions

    private func canMove(by delta: Int) -> Bool {
        guard let id = selection,
              let i = document.project.clips.firstIndex(where: { $0.id == id }) else { return false }
        return document.project.clips.indices.contains(i + delta)
    }

    private var canSetTarget: Bool {
        guard let id = selection else { return false }
        return id != document.project.targetClipID
    }

    private var canRelink: Bool {
        guard let id = selection else { return false }
        return document.importStates[id] == .sourceMissing
    }

    private func move(by delta: Int) {
        guard let id = selection else { return }
        document.move(id: id, by: delta)
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        document.deleteClip(id: id)
        selection = nil
    }

    private func openCutEditor(for clip: Clip) {
        cutEditor.open(clip: clip, document: document)
    }

    // MARK: - Drag & drop

    /// Append-drop onto the window chrome / empty state. Positional drops between
    /// rows are handled by the list's `onInsert`.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        loadVideoURLs(from: providers) { urls in
            if !urls.isEmpty { document.addFiles(urls) }
        }
        return true
    }

    /// Loads file URLs from drop providers, keeping only importable videos and
    /// preserving drop order, then delivers them on the main actor.
    private func loadVideoURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { completion([]); return }

        var results = [URL?](repeating: nil, count: fileProviders.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (i, provider) in fileProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, Self.isImportable(url) {
                    lock.lock(); results[i] = url; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results.compactMap { $0 })
        }
    }

    // MARK: - Importable types

    static let acceptedExtensions: Set<String> =
        ["ts", "m2ts", "mts", "mkv", "mpg", "mpeg", "m2v", "vob", "mp4", "mov", "m4v"]

    static let contentTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .mpeg2Video]
        for ext in acceptedExtensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()

    /// Whether a dropped file looks like an importable video — by extension, or by
    /// its type conforming to one we accept. Keeps stray files (text, images) out.
    static func isImportable(_ url: URL) -> Bool {
        if acceptedExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }
}
