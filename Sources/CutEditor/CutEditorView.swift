import SwiftUI

struct CutEditorView: View {
    @ObservedObject var model: CutEditorModel
    @ObservedObject var document: ProjectDocument
    @State private var showingAudioSettings = false
    @State private var jumpRelative = true

    var body: some View {
        VStack(spacing: 0) {
            preview
            controls
        }
        .frame(minWidth: 640, minHeight: 480)
        .scrollScrub { steps, keyframeStride in
            if keyframeStride {
                for _ in 0..<abs(steps) {
                    steps < 0 ? model.stepToPreviousKeyframe() : model.stepToNextKeyframe()
                }
            } else {
                model.step(by: steps)
            }
        }
        .sheet(isPresented: $showingAudioSettings) {
            AudioSettingsView(document: document, clipIDs: [model.clip.id])
        }
    }

    private var liveClip: Clip? {
        document.project.clips.first { $0.id == model.clip.id }
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
            audioTrackPicker
            Button {
                showingAudioSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Audio Settings…")
            Spacer()
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { model.confirm() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var audioTrackPicker: some View {
        if let clip = liveClip, !clip.resolvedAudioSelections.isEmpty {
            Picker("Audio:", selection: Binding(
                get: { min(clip.monitoredAudioTrack ?? 0, clip.resolvedAudioSelections.count - 1) },
                set: {
                    document.setMonitoredAudioTrack(id: clip.id, slot: $0)
                    model.monitoredAudioTrackChanged()
                }
            )) {
                ForEach(clip.resolvedAudioSelections.indices, id: \.self) { slot in
                    Text(clip.audioTrackName(slot)).tag(slot)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("The track heard during playback — the choice is saved with the project")
        }
    }

    private var scrubber: some View {
        CutScrubberView(model: model)
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
                .contentShape(Rectangle())
                .onTapGesture { model.isShowingJump = true }
                .help("Go to a time or frame (⌘J)")
                .popover(isPresented: $model.isShowingJump, arrowEdge: .bottom) {
                    JumpPopoverView(model: model, isPresented: $model.isShowingJump, relative: $jumpRelative)
                }
            Spacer()
            selectionReadout
        }
        .font(.callout)
    }

    private var selectionReadout: some View {
        HStack(spacing: 4) {
            Text("Selection")
                .foregroundStyle(.secondary)
            selectionPoint(model.inPoint, help: "Jump to the in point")
            Text("–")
                .foregroundStyle(.secondary)
            selectionPoint(model.outPoint, help: "Jump to the out point")
        }
    }

    @ViewBuilder
    private func selectionPoint(_ frame: Int?, help: String) -> some View {
        if let frame {
            Button(String(frame)) { model.seek(to: frame) }
                .buttonStyle(.link)
                .monospacedDigit()
                .help(help)
        } else {
            Text("—")
                .foregroundStyle(.secondary)
        }
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

            Divider().frame(height: 20).padding(.horizontal, 6)

            button("arrowtriangle.up.fill", help: "Previous scene change (↑)") {
                model.scanToSceneChange(forward: false)
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(model.isSceneScanning)
            button("arrowtriangle.down.fill", help: "Next scene change (↓)") {
                model.scanToSceneChange(forward: true)
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(model.isSceneScanning)
            ProgressView()
                .controlSize(.small)
                .frame(width: 20)
                .opacity(model.isSceneScanning ? 1 : 0)

            Divider().frame(height: 20).padding(.horizontal, 6)

            Button { model.setIn() } label: { Text("[").font(.title3.bold()).frame(width: 28) }
                .help("Set in point ( [ )")
                .keyboardShortcut("[", modifiers: [])
            Button { model.setOut() } label: { Text("]").font(.title3.bold()).frame(width: 28) }
                .help("Set out point ( ] )")
                .keyboardShortcut("]", modifiers: [])

            Divider().frame(height: 20).padding(.horizontal, 6)

            button("scissors", help: model.isSplitAtPlayhead
                   ? "Remove the split point at the playhead (⌘B)"
                   : "Split at the playhead (⌘B)") { model.toggleSplit() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!model.canToggleSplit)
        }
        .controlSize(.large)
        .disabled(model.isIndexing || model.frameCount == 0)
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
