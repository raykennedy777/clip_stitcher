import SwiftUI

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
                .scrollScrub { steps, keyframeStride in
                    if keyframeStride {
                        for _ in 0..<abs(steps) {
                            steps < 0 ? model.stepToPreviousKeyframe() : model.stepToNextKeyframe()
                        }
                    } else {
                        model.step(by: steps)
                    }
                }
            }
        }
        .navigationTitle("Preview")
        .task { await model.load() }
        .onDisappear { model.teardown() }
        .focusedSceneValue(\.saveFrame, SaveFrameCommand(isEnabled: model.canSaveFrame) {
            saveFrame()
        })
        .focusedSceneValue(\.previewTransport, PreviewTransport(
            isPlaying: model.isPlaying,
            canStep: !model.isLoading && model.frameCount > 0,
            togglePlay: { model.togglePlay() },
            step: { model.step(by: $0) },
            stepKeyframe: { $0 < 0 ? model.stepToPreviousKeyframe() : model.stepToNextKeyframe() }))
    }

    private func saveFrame() {
        guard let request = model.frameSnapshotRequest() else { return }
        FrameSnapshot.save(request)
    }

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

    private var controls: some View {
        VStack(spacing: 10) {
            scrubber
            readout
            transport
            if !model.outputTracks.isEmpty {
                HStack {
                    audioTrackPicker
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var audioTrackPicker: some View {
        Picker("Audio:", selection: Binding(
            get: { model.monitoredTrack },
            set: { model.setMonitoredTrack($0) }
        )) {
            ForEach(model.outputTracks.indices, id: \.self) { t in
                Text(model.trackName(t)).tag(t)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("The output track heard during playback — the choice is saved with the project")
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
            (Text(model.timecode(forFrame: model.currentFrame)).font(.body.weight(.medium))
                + Text("  /  \(model.timecode(forFrame: model.frameCount))").foregroundStyle(.secondary))
                .monospacedDigit()
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
            button("backward.fill", help: "Previous keyframe (⇧←)") { model.stepToPreviousKeyframe() }
            button("backward.frame.fill", help: "Back one frame (←)") { arrowJump(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])

            button(model.isPlaying ? "pause.fill" : "play.fill", help: "Play / Pause (Space)") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])

            button("forward.frame.fill", help: "Forward one frame (→)") { arrowJump(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            button("forward.fill", help: "Next keyframe (⇧→)") { model.stepToNextKeyframe() }
            button("forward.end.fill", help: "Last frame") { model.goToEnd() }
        }
        .controlSize(.large)
        .disabled(model.isLoading || model.frameCount == 0)
    }

    // ADR-0037
    private func arrowJump(_ delta: Int) {
        if NSEvent.modifierFlags.contains(.shift) {
            delta < 0 ? model.stepToPreviousKeyframe() : model.stepToNextKeyframe()
        } else {
            model.step(by: delta)
        }
    }

    private func button(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 28)
        }
        .help(help)
    }
}
