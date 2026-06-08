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
                Picker("Container", selection: output.container) {
                    ForEach(Container.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                HStack {
                    Button("Export…") { chooseDestinationAndExport() }
                        .disabled(document.project.clips.isEmpty || isExporting)
                    if isExporting {
                        ProgressView(value: exportFraction).frame(maxWidth: 160)
                    }
                    Spacer()
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
        if case .running(let p) = document.exportStatus { return p }
        return 0
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
        let ext = document.project.output.container.fileExtension
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
