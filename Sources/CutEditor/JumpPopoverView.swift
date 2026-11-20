import SwiftUI

struct JumpPopoverView: View {
    @ObservedObject var model: CutEditorModel
    @Binding var isPresented: Bool
    @Binding var relative: Bool

    @State private var timeText: String
    @State private var frameText: String
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
        guard let value else { return }
        model.seek(to: JumpParser.target(
            value: value, relative: relative, current: model.currentFrame))
        isPresented = false
    }
}
