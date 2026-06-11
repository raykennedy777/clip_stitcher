import SwiftUI

/// The jump popover (issue #21): time and frame fields anchored to the cut-editor
/// readout, opened with ⌘J or by clicking the readout. Return jumps to whichever
/// field was edited last and closes; Esc closes without moving; invalid input
/// does nothing so it can be corrected. The relative checkbox (ticked by default,
/// TMPGEnc semantics) makes the value an offset from the playhead — negative
/// moves backward; unticked, it's a position from the clip's first frame.
struct JumpPopoverView: View {
    @ObservedObject var model: CutEditorModel
    @Binding var isPresented: Bool
    /// Owned by the cut-editor window so the choice survives reopening the popover.
    @Binding var relative: Bool

    @State private var timeText: String
    @State private var frameText: String
    /// Which field Return acts on — the one edited last, nil when neither was
    /// touched (then Return just closes; the prefill is only a starting point).
    @State private var edited: Field?
    @FocusState private var focused: Field?

    enum Field { case time, frame }

    init(model: CutEditorModel, isPresented: Binding<Bool>, relative: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
        self._relative = relative
        if relative.wrappedValue {
            _timeText = State(initialValue: "00:00:00:00")
            _frameText = State(initialValue: "0")
        } else {
            _timeText = State(initialValue: model.timecode(forFrame: model.currentFrame))
            _frameText = State(initialValue: String(model.currentFrame))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 8) {
                GridRow {
                    Text("Time:")
                    TextField("00:00:00:00", text: $timeText)
                        .focused($focused, equals: .time)
                        .onSubmit(jump)
                        // Scroll over the field rolls its staged timecode a
                        // frame per step (issue #40) — never a live jump:
                        // Return commits (onChange marks it edited), Esc still
                        // bails. Absolute mode clamps at 0:00; Shift is
                        // meaningless here, so the stride flag is ignored.
                        .scrollScrub { steps, _ in
                            if let stepped = JumpParser.steppedTimecode(
                                timeText, by: steps, fps: model.fps, allowNegative: relative) {
                                timeText = stepped
                            }
                        }
                }
                GridRow {
                    Text("Frame:")
                    TextField("0", text: $frameText)
                        .focused($focused, equals: .frame)
                        .onSubmit(jump)
                        // Same rolling for the frame field, as a bare count.
                        .scrollScrub { steps, _ in
                            if let stepped = JumpParser.steppedFrames(
                                frameText, by: steps, allowNegative: relative) {
                                frameText = stepped
                            }
                        }
                }
            }
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 190)

            Toggle("Relative position", isOn: $relative)
                .help("Move by an offset from the current position — negative values go backward. Untick to go to a position counted from the clip's first frame.")
        }
        .padding(12)
        .onAppear { focused = .time }
        .onChange(of: timeText) { edited = .time }
        .onChange(of: frameText) { edited = .frame }
    }

    private func jump() {
        guard let edited else {
            isPresented = false
            return
        }
        let value: Int?
        switch edited {
        case .time: value = JumpParser.timecodeFrames(timeText, fps: model.fps)
        case .frame: value = JumpParser.frames(frameText)
        }
        guard let value else { return } // invalid input: stay open for correction
        model.seek(to: JumpParser.target(
            value: value, relative: relative, current: model.currentFrame))
        isPresented = false
    }
}
