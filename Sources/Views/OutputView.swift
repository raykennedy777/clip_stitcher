import SwiftUI
import AppKit

struct OutputView: View {
    @ObservedObject var document: ProjectDocument
    @State private var showCancelAlert = false
    private let panelDefaults = ExportPanelDefaults()

    private var output: Binding<OutputSettings> {
        Binding(
            get: { document.project.output },
            set: { document.setOutput($0) }
        )
    }

    private var isExporting: Bool {
        if case .running = document.exportStatus { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Output") {
                Picker("Mode", selection: output.mode) {
                    ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("output.mode")
                if document.project.output.mode == .separate {
                    Picker("Rendering", selection: output.rendering) {
                        ForEach(SeparateRendering.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("output.rendering")
                }
                Picker("Type", selection: output.type) {
                    ForEach(OutputType.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("output.type")
                if document.project.output.type != .audioOnly {
                    Picker("Container", selection: output.container) {
                        ForEach(Container.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("output.container")
                }
            }

            Section {
                if let warning = reencodeDominanceWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("output.reencodeWarning")
                        .accessibilityValue(Text(warning))
                }
                HStack {
                    Button("Export…") { chooseDestinationAndExport() }
                        .disabled(document.project.clips.isEmpty || isExporting || exportDisabledReason != nil)
                        .accessibilityIdentifier("output.export")
                    Spacer()
                }
                if !isExporting, let reason = exportDisabledReason {
                    Label(reason, systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("output.exportBlockedReason")
                        .accessibilityValue(Text(reason))
                }
                if isExporting {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            ProgressView(value: exportFraction)
                            Button("Cancel Export…") { showCancelAlert = true }
                                .disabled(document.exportCancelRequested)
                        }
                        HStack {
                            Text(exportFraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                            Spacer()
                            if let eta = exportETA {
                                Text(eta)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                exportOutcome
            } footer: {
                Text("Cuts land on the exact frame you chose. Footage is stream-copied "
                     + "untouched wherever clean cut points allow; the rest is re-encoded. "
                     + "Each clip's row shows its copied share.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Output")
        .alert("Cancel the export?", isPresented: $showCancelAlert) {
            Button("Cancel Export", role: .destructive) { document.cancelExport() }
            Button("Continue Exporting", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Progress so far will be discarded.")
        }
        .onChange(of: isExporting) { _, running in
            if !running { showCancelAlert = false }
        }
    }

    private var reencodeDominanceWarning: String? {
        guard document.project.output.type != .audioOnly else { return nil }
        let shares = document.project.clips.compactMap { document.copyShares[$0.id] }
        return ExportPlanner.reencodeDominanceWarning(shares: shares)
    }

    private var exportDisabledReason: String? {
        ProjectDocument.exportDisabledReason(
            clips: document.project.clips, states: document.importStates)
    }

    private var exportFraction: Double {
        if case .running(let p, _) = document.exportStatus { return p }
        return 0
    }

    private var exportETA: String? {
        if case .running(_, let eta) = document.exportStatus { return eta }
        return nil
    }

    @ViewBuilder
    private var exportOutcome: some View {
        switch document.exportStatus {
        case .idle, .running:
            EmptyView()
        case .done(let warnings):
            VStack(alignment: .leading, spacing: 4) {
                Label("Export complete.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "scissors")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("output.status")
            .accessibilityValue(Text((["Export complete."] + warnings).joined(separator: " ")))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityIdentifier("output.status")
                .accessibilityValue(Text(message))
        case .cancelled(let detail):
            Label(detail.map { "Export cancelled — \($0)" } ?? "Export cancelled.",
                  systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("output.status")
        }
    }

    private func chooseDestinationAndExport() {
        if document.project.output.mode == .separate {
            if let dest = AutomationOverrides.current?.exportDestination {
                document.startExport(to: dest)
                return
            }
            let panel = NSOpenPanel()
            panel.title = "Export"
            panel.prompt = "Export"
            panel.message = "Choose a folder for the exported clips."
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if let dir = panelDefaults.startingDirectory ?? defaultExportDirectory {
                panel.directoryURL = dir
            }

            guard panel.runModal() == .OK, let url = panel.url else { return }
            panelDefaults.recordChosenFolder(url)
            document.startExport(to: url)
            return
        }
        let out = document.project.output
        let ext: String
        if out.type == .audioOnly {
            let choice = AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: document.project.targetClip?.audio?.codec)
            ext = AudioCodecPolicy.audioFileExtension(forEncoder: choice.encoder)
        } else {
            ext = out.container.fileExtension
        }
        if var url = AutomationOverrides.current?.exportDestination {
            if url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
            document.startExport(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.nameFieldStringValue = "\(defaultName).\(ext)"
        if let dir = panelDefaults.startingDirectory ?? defaultExportDirectory {
            panel.directoryURL = dir
        }

        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
        panelDefaults.recordChosenFile(url)
        document.startExport(to: url)
    }

    private var defaultExportDirectory: URL? {
        let candidates = [document.project.targetClip, document.project.clips.first]
        for clip in candidates {
            if let clip, let url = document.url(for: clip) {
                return url.deletingLastPathComponent()
            }
        }
        return nil
    }

    private var defaultName: String {
        if let first = document.project.clips.first {
            let stem = (first.displayName as NSString).deletingPathExtension
            return stem.isEmpty ? "Clip Stitcher Export" : stem
        }
        return "Clip Stitcher Export"
    }
}
