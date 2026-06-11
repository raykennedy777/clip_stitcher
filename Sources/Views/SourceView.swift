import SwiftUI
import UniformTypeIdentifiers

struct SourceView: View {
    @ObservedObject var document: ProjectDocument
    @EnvironmentObject private var cutEditor: CutEditorPresenter
    @State private var selection: Set<Clip.ID> = []
    @State private var importing = false
    @State private var importPurpose: ImportPurpose = .add
    @State private var isDropTargeted = false
    /// The clips an open Audio Settings sheet edits, in timeline order; empty when
    /// the sheet is closed. More than one only under the same-source gate.
    @State private var audioSettingsClips: [Clip.ID] = []

    /// What a presented file picker is for. A single `.fileImporter` serves both jobs —
    /// stacking two of the same presentation modifier on one view silently breaks all but
    /// the last, which once left "Add File" doing nothing.
    private enum ImportPurpose {
        case add
        case relink(Set<Clip.ID>)
    }

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
        .sheet(isPresented: Binding(
            get: { !audioSettingsClips.isEmpty },
            set: { if !$0 { audioSettingsClips = [] } }
        )) {
            if !audioSettingsClips.isEmpty {
                AudioSettingsView(document: document, clipIDs: audioSettingsClips)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: Self.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            switch importPurpose {
            case .add:
                document.addFiles(urls)
            case .relink(let ids):
                if let url = urls.first { document.relink(ids: ids, to: url) }
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
                        state: document.importStates[clip.id] ?? .ready,
                        url: document.url(for: clip),
                        share: document.copyShares[clip.id]
                    )
                    .tag(clip.id)
                    // A container, not a flattened element — so the badge keeps its
                    // own `source.clip.<index>.role` identifier and value (issue #5).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("source.clip.\(index)")
                    // Native NSTableView double-click → open the cut-editor, without
                    // disturbing the List's single-click selection + highlight.
                    .background(ListDoubleClickAction { row in
                        let clips = document.project.clips
                        guard clips.indices.contains(row) else { return }
                        let clip = clips[row]
                        selection = [clip.id]
                        openCutEditor(for: clip)
                    })
                    // Acts on the whole selection when the row under the pointer is
                    // part of it, else on just that row (macOS convention).
                    .contextMenu {
                        let targets = contextTargets(for: clip)
                        Button("Open in Cut-Editor") {
                            selection = [clip.id]
                            openCutEditor(for: clip)
                        }
                        Button("Duplicate") { duplicate(targets) }
                        Button("Audio Settings…") { presentAudioSettings(for: targets) }
                            .disabled(!allSameSource(targets))
                        Divider()
                        Button("Delete", role: .destructive) { delete(targets) }
                    }
                }
                .onInsert(of: [.fileURL]) { index, providers in
                    loadVideoURLs(from: providers) { urls in
                        if !urls.isEmpty { document.addFiles(urls, at: index) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onKeyPress(.return) {
                // The cut-editor opens one clip — only an unambiguous selection.
                if selection.count == 1, let id = selection.first,
                   let clip = document.project.clips.first(where: { $0.id == id }) {
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
            // Backspace / forward delete remove the selected clips — the keyboard
            // path to the Delete button and context-menu item (issue #42).
            // Backspace reaches the list as DEL (U+007F), not `.delete` (BS, U+0008),
            // so match both; forward delete arrives with the .function modifier, so
            // only reject the modifiers that would make this a different chord.
            .onKeyPress(keys: ["\u{7F}", .delete, .deleteForward]) { press in
                let chordModifiers: EventModifiers = [.command, .option, .control, .shift]
                guard press.modifiers.isDisjoint(with: chordModifiers),
                      !selection.isEmpty else { return .ignored }
                delete(selection)
                return .handled
            }
        }
    }

    private func role(for clip: Clip) -> ClipRole {
        ClipRole.role(for: clip, target: document.project.targetClip,
                      output: document.project.output)
    }

    // MARK: - Action panel

    private var actionPanel: some View {
        VStack(spacing: 8) {
            action("Add File", systemImage: "plus", id: "source.addFile") {
                // Automation bypass (issue #37): sources come from the environment
                // instead of an open panel; the import pipeline is unchanged.
                if let sources = AutomationOverrides.current?.importSources, !sources.isEmpty {
                    document.addFiles(sources)
                    return
                }
                importPurpose = .add; importing = true
            }

            Divider().padding(.vertical, 6)

            action("Move Up", systemImage: "arrow.up", id: "source.moveUp",
                   enabled: canMove(by: -1)) { move(by: -1) }
            action("Move Down", systemImage: "arrow.down", id: "source.moveDown",
                   enabled: canMove(by: 1)) { move(by: 1) }
            action("Duplicate", systemImage: "plus.square.on.square", id: "source.duplicate",
                   enabled: !selection.isEmpty) {
                duplicate(selection)
            }
            action("Delete", systemImage: "trash", id: "source.delete",
                   enabled: !selection.isEmpty) { delete(selection) }
            action("Clear", systemImage: "xmark.bin", id: "source.clear",
                   enabled: !document.project.clips.isEmpty) {
                document.clearAll()
                selection = []
            }

            Divider().padding(.vertical, 6)

            action("Audio Settings…", systemImage: "waveform", id: "source.audioSettings",
                   enabled: canOpenAudioSettings) {
                presentAudioSettings(for: selection)
            }
            action("Set as Target Clip", systemImage: "target", id: "source.setTarget",
                   enabled: canSetTarget) {
                if let id = selection.first { document.setTarget(id: id) }
            }
            action("Relink…", systemImage: "link", id: "source.relink",
                   enabled: canRelink) {
                if let source = AutomationOverrides.current?.relinkSource {
                    document.relink(ids: selection, to: source)
                    return
                }
                importPurpose = .relink(selection)
                importing = true
            }

            Spacer()
        }
        .labelStyle(FixedIconColumnLabelStyle())
        .padding()
        .frame(width: 200)
    }

    private func action(_ title: String, systemImage: String, id: String, enabled: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    // MARK: - Selection helpers (issue #12)

    /// The selected rows' positions in timeline order — the selection set itself
    /// carries no order.
    private func indices(of ids: Set<Clip.ID>) -> Set<Int> {
        Set(document.project.clips.enumerated()
            .filter { ids.contains($0.element.id) }.map(\.offset))
    }

    /// What a context-menu item acts on: the whole selection when the right-clicked
    /// row is part of it, else just that row.
    private func contextTargets(for clip: Clip) -> Set<Clip.ID> {
        selection.contains(clip.id) ? selection : [clip.id]
    }

    /// A clip's identity for the same-source gate: its resolved URL when the file is
    /// reachable, else its raw bookmark — so duplicated rows of a now-missing file
    /// (byte-identical bookmarks) still count as one source for Relink.
    private func sourceKey(for clip: Clip) -> String? {
        if let url = document.url(for: clip) { return "url:\(url.standardizedFileURL.path)" }
        return clip.bookmark.isEmpty ? nil : "bookmark:\(clip.bookmark.base64EncodedString())"
    }

    private func allSameSource(_ ids: Set<Clip.ID>) -> Bool {
        let keys = document.project.clips
            .filter { ids.contains($0.id) }
            .map { sourceKey(for: $0) }
        return BatchSelection.allSameSource(keys)
    }

    // MARK: - Actions

    private func canMove(by delta: Int) -> Bool {
        BatchSelection.canMove(count: document.project.clips.count,
                               selected: indices(of: selection), delta: delta)
    }

    /// The target is a single role — only an unambiguous selection can assign it.
    private var canSetTarget: Bool {
        selection.count == 1 && selection.first != document.project.targetClipID
    }

    /// Relink rebinds the selection to one picked file, so every selected clip must
    /// be source-missing and they must all have pointed at the same file.
    private var canRelink: Bool {
        !selection.isEmpty
            && selection.allSatisfy { document.importStates[$0] == .sourceMissing }
            && allSameSource(selection)
    }

    /// The sheet's track list must hold for every clip it writes to, so all
    /// selected clips must share the same source file.
    private var canOpenAudioSettings: Bool {
        !selection.isEmpty && allSameSource(selection)
    }

    private func presentAudioSettings(for ids: Set<Clip.ID>) {
        audioSettingsClips = document.project.clips.map(\.id).filter { ids.contains($0) }
    }

    private func move(by delta: Int) {
        document.move(ids: selection, by: delta)
    }

    private func delete(_ ids: Set<Clip.ID>) {
        document.deleteClips(ids: ids)
        selection.subtract(ids)
    }

    /// Duplicates the clips and selects the copies, Finder-style.
    private func duplicate(_ ids: Set<Clip.ID>) {
        let newIDs = document.duplicateClips(ids: ids)
        if !newIDs.isEmpty {
            selection = Set(newIDs)
        }
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

/// Pins every icon into a uniform 28 pt slot (same width as `PreviewView`'s
/// transport buttons) so button titles share one left edge regardless of how
/// wide each SF Symbol happens to be.
private struct FixedIconColumnLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.frame(width: 28)
            configuration.title
        }
    }
}
