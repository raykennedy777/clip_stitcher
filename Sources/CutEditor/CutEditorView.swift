import SwiftUI

struct CutEditorView: View {
    @ObservedObject var model: CutEditorModel
    /// Observed so the audio track dropdown follows live edits from the settings sheet.
    @ObservedObject var document: ProjectDocument
    @State private var showingAudioSettings = false
    @State private var showingJump = false
    /// The jump popover's relative/absolute choice, kept here so it persists
    /// while the window is open (issue #21).
    @State private var jumpRelative = true

    var body: some View {
        VStack(spacing: 0) {
            preview
            controls
        }
        .frame(minWidth: 640, minHeight: 480)
        // Scroll anywhere over the window scrubs (issue #40); Shift strides
        // keyframes, mirroring ⇧←/⇧→.
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

    /// The clip's live state in the document (the model's copy is a snapshot from
    /// when the window opened).
    private var liveClip: Clip? {
        document.project.clips.first { $0.id == model.clip.id }
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

    /// Which of the clip's audio tracks to monitor (ADR-0014) — the track heard
    /// during playback (issue #7; switching mid-play restarts the stream on the
    /// new source). Tracks are named from container metadata with the "Track N"
    /// fallback.
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
            // The timecode readout doubles as the jump popover's anchor (issue
            // #21): click it — or ⌘J via the hidden button — to go to a typed
            // time or frame.
            Text(model.timecode(forFrame: model.currentFrame))
                .monospacedDigit()
                .font(.body.weight(.medium))
                .contentShape(Rectangle())
                .onTapGesture { showingJump = true }
                .help("Go to a time or frame (⌘J)")
                .popover(isPresented: $showingJump, arrowEdge: .bottom) {
                    JumpPopoverView(model: model, isPresented: $showingJump, relative: $jumpRelative)
                }
                .background(
                    Button("") { showingJump = true }
                        .keyboardShortcut("j", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                )
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

    /// A set selection point reads as a link that jumps the playhead to its frame.
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
            // One registered shortcut per arrow key, dispatching on the live Shift
            // state: SwiftUI matches arrow-key equivalents ignoring Shift, so two
            // buttons declaring ← and ⇧← both fire the first-registered one.
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
            // Fixed-size slot so the spinner's appearance doesn't shift the row.
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

    /// ←/→ step a frame; with Shift held they jump a keyframe instead.
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
