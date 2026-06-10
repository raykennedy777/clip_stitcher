import SwiftUI
import AppKit

struct OutputView: View {
    @ObservedObject var document: ProjectDocument

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
                Picker("Type", selection: output.type) {
                    ForEach(OutputType.allCases) { Text($0.title).tag($0) }
                }
                // The video container doesn't apply to an audio-only export — it's written as
                // an audio-elementary file whose type follows the audio codec (#1).
                if document.project.output.type != .audioOnly {
                    Picker("Container", selection: output.container) {
                        ForEach(Container.allCases) { Text($0.title).tag($0) }
                    }
                }
            }

            Section {
                HStack {
                    Button("Export…") { chooseDestinationAndExport() }
                        .disabled(document.project.clips.isEmpty || isExporting)
                    Spacer()
                }
                if isExporting {
                    // Prominent progress (issue #9): a full-width determinate bar with
                    // percent and a damped "About X remaining" readout beneath it.
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: exportFraction)
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
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func chooseDestinationAndExport() {
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
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(defaultName).\(ext)"

        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
        Task { await document.export(to: url) }
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
