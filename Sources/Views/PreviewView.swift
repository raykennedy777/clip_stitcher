import SwiftUI

/// The Output Preview (sidebar "Preview"): scrubs the assembled timeline by decoding
/// source frames on demand (ADR-0012). Mirrors the cut-editor's layout so the two
/// frame views feel like siblings.
struct PreviewView: View {
    @StateObject private var model: PreviewModel

    init(document: ProjectDocument) {
        _model = StateObject(wrappedValue: PreviewModel(document: document))
    }

    var body: some View {
        Group {
            if let status = model.statusMessage {
                ContentUnavailableView(
                    "Output Preview",
                    systemImage: "play.rectangle",
                    description: Text(status)
                )
            } else {
                VStack(spacing: 0) {
                    preview
                    controls
                }
            }
        }
        .navigationTitle("Preview")
        .task { await model.load() }
        .onDisappear { model.teardown() }
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
            if model.isLoading {
                ProgressView("Building frame index…")
                    .controlSize(.large)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = model.errorMessage {
                ContentUnavailableView("Can't preview", systemImage: "exclamationmark.triangle", description: Text(message))
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
        }
        .padding(12)
        .background(.bar)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { Double(model.currentFrame) },
                    set: { model.seek(to: Int($0.rounded())) }
                ),
                in: 0...Double(max(1, model.lastFrame))
            )
            .disabled(model.isLoading || model.frameCount == 0)
            joinMarkers
        }
    }

    /// Tick marks under the scrubber at each join (where one clip ends and the next
    /// begins). Inset to roughly match the slider knob's travel.
    private var joinMarkers: some View {
        GeometryReader { geo in
            let inset: CGFloat = 10
            let travel = max(1, geo.size.width - inset * 2)
            ForEach(model.joinFrames, id: \.self) { frame in
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 2, height: 6)
                    .position(
                        x: inset + travel * CGFloat(frame) / CGFloat(max(1, model.lastFrame)),
                        y: 3
                    )
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
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
            Text(model.currentClipName ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            button("backward.end.fill", help: "First frame") { model.goToStart() }
            button("backward.frame.fill", help: "Back one frame (←)") { model.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            button("forward.frame.fill", help: "Forward one frame (→)") { model.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            button("forward.end.fill", help: "Last frame") { model.goToEnd() }
        }
        .controlSize(.large)
        .disabled(model.isLoading || model.frameCount == 0)
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 28)
        }
        .help(help)
    }
}
