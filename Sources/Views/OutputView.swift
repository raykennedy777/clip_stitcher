import SwiftUI
import AppKit

struct OutputView: View {
    @ObservedObject var document: ProjectDocument
    @State private var showCancelAlert = false

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
                // Cut-only is a separate-mode rendering choice (ADR-0018) — connect
                // mode always conforms, so the picker only appears here.
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
                // The video container doesn't apply to an audio-only export — it's written as
                // an audio-elementary file whose type follows the audio codec (#1).
                if document.project.output.type != .audioOnly {
                    Picker("Container", selection: output.container) {
                        ForEach(Container.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("output.container")
                }
            }

            Section {
                HStack {
                    Button("Export…") { chooseDestinationAndExport() }
                        .disabled(document.project.clips.isEmpty || isExporting)
                        .accessibilityIdentifier("output.export")
                    Spacer()
                }
                if isExporting {
                    // Prominent progress (issue #9): a full-width determinate bar with
                    // percent and a damped "About X remaining" readout beneath it.
                    // The ellipsis on Cancel Export… is deliberate — the command asks
                    // for confirmation first (issue #32).
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
                Text("Cuts land on the exact frame you chose. Everything between the "
                     + "boundaries is stream-copied untouched; only the partial GOPs at "
                     + "the in/out points are re-encoded.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Output")
        // The export keeps running while the alert is up; Continue Exporting is the
        // default (Return), the destructive confirm actually cancels (issue #32).
        .alert("Cancel the export?", isPresented: $showCancelAlert) {
            Button("Cancel Export", role: .destructive) { document.cancelExport() }
            Button("Continue Exporting", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Progress so far will be discarded.")
        }
        // If the export finishes (or fails) while the alert is still up, there is
        // nothing left to cancel — dismiss it and let the outcome show.
        .onChange(of: isExporting) { _, running in
            if !running { showCancelAlert = false }
        }
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
            // Neutral, not red — nothing went wrong (issue #32).
            Label(detail.map { "Export cancelled — \($0)" } ?? "Export cancelled.",
                  systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("output.status")
        }
    }

    private func chooseDestinationAndExport() {
        // Separate mode writes one file per clip, named `NN <clip name>.<ext>` in
        // timeline order — so the user picks the folder they all land in, not a
        // filename (issue #30). Connect mode keeps the filename save panel.
        if document.project.output.mode == .separate {
            // Automation bypass (issue #37): the destination folder comes from the
            // environment instead of a panel; the export itself is unchanged.
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
            if let dir = defaultExportDirectory { panel.directoryURL = dir }

            guard panel.runModal() == .OK, let url = panel.url else { return }
            document.startExport(to: url)
            return
        }
        // An audio-only export is an audio-elementary file named for the (target-derived)
        // audio codec, not the video container (#1 / ADR-0010).
        let out = document.project.output
        let ext: String
        if out.type == .audioOnly {
            let choice = AudioCodecPolicy.resolveAudioOnlyCodec(targetCodec: document.project.targetClip?.audio?.codec)
            ext = AudioCodecPolicy.audioFileExtension(forEncoder: choice.encoder)
        } else {
            ext = out.container.fileExtension
        }
        // Automation bypass (issue #37): same extension fix-up the panel path does.
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
        if let dir = defaultExportDirectory { panel.directoryURL = dir }

        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
        document.startExport(to: url)
    }

    /// Where the export panel opens: the target clip's folder, else the first clip's.
    /// Nil (unresolvable bookmarks, no clips) leaves the panel at the system default.
    private var defaultExportDirectory: URL? {
        let candidates = [document.project.targetClip, document.project.clips.first]
        for clip in candidates {
            if let clip, let url = document.url(for: clip) {
                return url.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// A starting filename: the first clip's name without its extension, else a default.
    private var defaultName: String {
        if let first = document.project.clips.first {
            let stem = (first.displayName as NSString).deletingPathExtension
            return stem.isEmpty ? "VidConform Export" : stem
        }
        return "VidConform Export"
    }
}
