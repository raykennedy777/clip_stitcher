import SwiftUI
import UniformTypeIdentifiers

struct SourceView: View {
    @ObservedObject var document: ProjectDocument
    @EnvironmentObject private var cutEditor: CutEditorPresenter
    @State private var selection: Set<Clip.ID> = []
    @SceneStorage("source.inspector.shown") private var inspectorShown = false
    @State private var importing = false
    @State private var importPurpose: ImportPurpose = .add
    @State private var isDropTargeted = false
    @State private var audioSettingsClips: [Clip.ID] = []
    @State private var doctorTarget: DoctorTarget?

    // ADR-0037
    private enum ImportPurpose {
        case add
        case relink(Set<Clip.ID>)
    }

    private struct DoctorTarget: Identifiable { let id: Clip.ID }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                inOutResetBanner
                doctorBanner
                clipList
            }
            .sheet(item: $doctorTarget) { target in
                ClipDoctorView(document: document, clipID: target.id)
            }
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
        .inspector(isPresented: $inspectorShown) {
            ClipInspectorView(document: document, selection: selection)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    inspectorShown.toggle()
                } label: {
                    Label("Clip Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the clip inspector")
                .keyboardShortcut("i", modifiers: [.command, .option])
                .accessibilityIdentifier("inspector.toggle")
            }
        }
    }

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
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("source.clip.\(index)")
                    .background(ListDoubleClickAction { row in
                        let clips = document.project.clips
                        guard clips.indices.contains(row) else { return }
                        let clip = clips[row]
                        selection = [clip.id]
                        openCutEditor(for: clip)
                    })
                    .contextMenu {
                        let targets = contextTargets(for: clip)
                        Button("Open in Cut-Editor") {
                            selection = [clip.id]
                            openCutEditor(for: clip)
                        }
                        Button("Duplicate") { duplicate(targets) }
                        Button("Audio Settings…") { presentAudioSettings(for: targets) }
                            .disabled(!allSameSource(targets))
                        Button("Clip Doctor…") { presentDoctor(for: clip.id) }
                            .disabled(!canDoctor(clip))
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
                if selection.count == 1, let id = selection.first,
                   let clip = document.project.clips.first(where: { $0.id == id }) {
                    openCutEditor(for: clip)
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                move(by: press.key == .upArrow ? -1 : 1)
                return .handled
            }
            // ADR-0037
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

    private var actionPanel: some View {
        VStack(spacing: 8) {
            action("Add File", systemImage: "plus", id: "source.addFile") {
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
            action("Clip Doctor…", systemImage: "bandage", id: "source.clipDoctor",
                   enabled: canDoctorSelection) {
                if let id = selection.first { presentDoctor(for: id) }
            }
            if let notice = audioOnlyDoctorNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("source.clipDoctorBlockedReason")
                    .accessibilityValue(Text(notice))
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

    private func indices(of ids: Set<Clip.ID>) -> Set<Int> {
        Set(document.project.clips.enumerated()
            .filter { ids.contains($0.element.id) }.map(\.offset))
    }

    private func contextTargets(for clip: Clip) -> Set<Clip.ID> {
        selection.contains(clip.id) ? selection : [clip.id]
    }

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

    private func canMove(by delta: Int) -> Bool {
        BatchSelection.canMove(count: document.project.clips.count,
                               selected: indices(of: selection), delta: delta)
    }

    private var canSetTarget: Bool {
        selection.count == 1 && selection.first != document.project.targetClipID
    }

    private var canRelink: Bool {
        !selection.isEmpty
            && selection.allSatisfy { document.importStates[$0] == .sourceMissing }
            && allSameSource(selection)
    }

    private var canOpenAudioSettings: Bool {
        !selection.isEmpty && allSameSource(selection)
    }

    private func presentAudioSettings(for ids: Set<Clip.ID>) {
        audioSettingsClips = document.project.clips.map(\.id).filter { ids.contains($0) }
    }

    private func canDoctor(_ clip: Clip) -> Bool {
        (clip.damageZones?.contains(where: \.affectsVideo) ?? false)
            && document.importStates[clip.id] != .sourceMissing
            && document.url(for: clip) != nil
            && (clip.fieldCoded != true || ClipDoctorEngine.canRepairFieldCoded(codec: clip.video?.codec))
    }

    private var canDoctorSelection: Bool {
        guard selection.count == 1, let id = selection.first,
              let clip = document.project.clips.first(where: { $0.id == id }) else { return false }
        return canDoctor(clip)
    }

    private var audioOnlyDoctorNotice: String? {
        guard selection.count == 1, let id = selection.first,
              document.importStates[id] == .failed(ProjectDocument.noVideoTrackFailure)
        else { return nil }
        return "Clip Doctor repairs video sources only."
    }

    private func presentDoctor(for id: Clip.ID) {
        selection = [id]
        document.dismissDoctorSuggestion(id)
        doctorTarget = DoctorTarget(id: id)
    }

    private var doctorBannerClip: Clip? {
        for id in document.doctorSuggestions {
            if let clip = document.project.clips.first(where: { $0.id == id }), canDoctor(clip) {
                return clip
            }
        }
        return nil
    }

    @ViewBuilder
    private var doctorBanner: some View {
        if let clip = doctorBannerClip {
            HStack(spacing: 12) {
                Image(systemName: "bandage")
                    .foregroundStyle(.orange)
                Text(ClipDoctorEngine.suggestionBannerText(
                    clipName: clip.displayName, zoneCount: (clip.damageZones ?? []).count))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Clip Doctor…") { presentDoctor(for: clip.id) }
                    .accessibilityIdentifier("source.doctorBanner.open")
                Button {
                    document.dismissDoctorSuggestion(clip.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityIdentifier("source.doctorBanner.dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .accessibilityIdentifier("source.doctorBanner")
        }
    }

    private var inOutResetClip: Clip? {
        for id in document.inOutResets {
            if let clip = document.project.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    @ViewBuilder
    private var inOutResetBanner: some View {
        if let clip = inOutResetClip {
            HStack(spacing: 12) {
                Image(systemName: "scissors.badge.ellipsis")
                    .foregroundStyle(.orange)
                Text("The in/out points for “\(clip.displayName)” couldn’t be kept as saved and were adjusted — review them before exporting.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    document.dismissInOutReset(clip.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityIdentifier("source.inOutResetBanner.dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .accessibilityIdentifier("source.inOutResetBanner")
        }
    }

    private func move(by delta: Int) {
        document.move(ids: selection, by: delta)
    }

    private func delete(_ ids: Set<Clip.ID>) {
        document.deleteClips(ids: ids)
        selection.subtract(ids)
    }

    private func duplicate(_ ids: Set<Clip.ID>) {
        let newIDs = document.duplicateClips(ids: ids)
        if !newIDs.isEmpty {
            selection = Set(newIDs)
        }
    }

    private func openCutEditor(for clip: Clip) {
        cutEditor.open(clip: clip, document: document)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard providers.contains(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }
        loadVideoURLs(from: providers) { urls in
            if !urls.isEmpty { document.addFiles(urls) }
        }
        return true
    }

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

    static func isImportable(_ url: URL) -> Bool {
        if acceptedExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }
}

private struct FixedIconColumnLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.frame(width: 28)
            configuration.title
        }
    }
}
