import SwiftUI

struct CutEditorView: View {
    @ObservedObject var model: CutEditorModel

    var body: some View {
        VStack(spacing: 0) {
            preview
            controls
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Preview area

    private var preview: some View {
        ZStack {
            Color.black
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
            if model.isIndexing {
                ProgressView("Building frame index…")
                    .controlSize(.large)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = model.errorMessage {
                ContentUnavailableView("Can't read clip", systemImage: "exclamationmark.triangle", description: Text(message))
                    .background(.thinMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            scrubber
            readout
            transport
            Divider()
            confirmBar
        }
        .padding(12)
        .background(.bar)
    }

    private var confirmBar: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { model.confirm() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { Double(model.currentFrame) },
                set: { model.seek(to: Int($0.rounded())) }
            ),
            in: 0...Double(max(1, model.lastFrame))
        )
        .disabled(model.isIndexing || model.frameCount == 0)
    }

    private var readout: some View {
        HStack {
            Text("Frame \(model.currentFrame) / \(model.lastFrame)")
                .monospacedDigit()
            Spacer()
            Text(model.timecode(forFrame: model.currentFrame))
                .monospacedDigit()
                .font(.body.weight(.medium))
            Spacer()
            Text(selectionText)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var selectionText: String {
        let start = model.inPoint.map(String.init) ?? "—"
        let end = model.outPoint.map(String.init) ?? "—"
        return "Selection \(start) – \(end)"
    }

    private var transport: some View {
        HStack(spacing: 8) {
            button("backward.end.fill", help: "First frame") { model.goToStart() }
            button("backward.frame.fill", help: "Back one frame (←)") { model.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])

            button(model.isPlaying ? "pause.fill" : "play.fill", help: "Play / Pause (Space)") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])

            button("forward.frame.fill", help: "Forward one frame (→)") { model.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            button("forward.end.fill", help: "Last frame") { model.goToEnd() }

            Divider().frame(height: 20).padding(.horizontal, 6)

            Button { model.setIn() } label: { Text("[").font(.title3.bold()).frame(width: 28) }
                .help("Set in point ( [ )")
                .keyboardShortcut("[", modifiers: [])
            Button { model.setOut() } label: { Text("]").font(.title3.bold()).frame(width: 28) }
                .help("Set out point ( ] )")
                .keyboardShortcut("]", modifiers: [])
        }
        .controlSize(.large)
        .disabled(model.isIndexing || model.frameCount == 0)
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 28)
        }
        .help(help)
    }
}
