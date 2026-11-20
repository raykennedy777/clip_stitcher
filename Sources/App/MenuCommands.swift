import SwiftUI

struct PreviewTransport {
    let isPlaying: Bool
    let canStep: Bool
    let togglePlay: () -> Void
    let step: (Int) -> Void
    let stepKeyframe: (Int) -> Void
}

private struct PreviewTransportKey: FocusedValueKey {
    typealias Value = PreviewTransport
}

extension FocusedValues {
    var previewTransport: PreviewTransport? {
        get { self[PreviewTransportKey.self] }
        set { self[PreviewTransportKey.self] = newValue }
    }
}

struct PlaybackCommands: View {
    @ObservedObject private var active = ActiveCutEditor.shared
    @FocusedValue(\.previewTransport) private var preview

    var body: some View {
        if let model = active.model {
            CutEditorTransportMenu(model: model)
        } else if let preview {
            TransportMenuItems(
                isPlaying: preview.isPlaying, canPlay: preview.canStep, canScene: false,
                togglePlay: preview.togglePlay, step: preview.step,
                keyframe: preview.stepKeyframe, scene: { _ in })
        } else {
            TransportMenuItems(
                isPlaying: false, canPlay: false, canScene: false,
                togglePlay: {}, step: { _ in }, keyframe: { _ in }, scene: { _ in })
        }
    }
}

private struct CutEditorTransportMenu: View {
    @ObservedObject var model: CutEditorModel

    var body: some View {
        TransportMenuItems(
            isPlaying: model.isPlaying, canPlay: model.canStep, canScene: model.canScene,
            togglePlay: model.togglePlay,
            step: { model.step(by: $0) },
            keyframe: { $0 < 0 ? model.stepToPreviousKeyframe() : model.stepToNextKeyframe() },
            scene: { model.scanToSceneChange(forward: $0) })
    }
}

private struct TransportMenuItems: View {
    let isPlaying: Bool
    let canPlay: Bool
    let canScene: Bool
    let togglePlay: () -> Void
    let step: (Int) -> Void
    let keyframe: (Int) -> Void
    let scene: (Bool) -> Void

    var body: some View {
        Button(isPlaying ? "Pause" : "Play") { togglePlay() }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!canPlay)
            .accessibilityIdentifier("menu.playback.playPause")

        Divider()

        Button("Step Backward") { step(-1) }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!canPlay)
            .accessibilityIdentifier("menu.playback.stepBackward")
        Button("Step Forward") { step(1) }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!canPlay)
            .accessibilityIdentifier("menu.playback.stepForward")

        Divider()

        Button("Previous Keyframe") { keyframe(-1) }
            .keyboardShortcut(.leftArrow, modifiers: .shift)
            .disabled(!canPlay)
            .accessibilityIdentifier("menu.playback.previousKeyframe")
        Button("Next Keyframe") { keyframe(1) }
            .keyboardShortcut(.rightArrow, modifiers: .shift)
            .disabled(!canPlay)
            .accessibilityIdentifier("menu.playback.nextKeyframe")

        Divider()

        Button("Previous Scene") { scene(false) }
            .keyboardShortcut(.upArrow, modifiers: [])
            .disabled(!canScene)
            .accessibilityIdentifier("menu.playback.previousScene")
        Button("Next Scene") { scene(true) }
            .keyboardShortcut(.downArrow, modifiers: [])
            .disabled(!canScene)
            .accessibilityIdentifier("menu.playback.nextScene")
    }
}

struct MarkingCommands: View {
    @ObservedObject private var active = ActiveCutEditor.shared

    var body: some View {
        if let model = active.model {
            CutEditorMarkingMenu(model: model)
        } else {
            MarkingMenuItems(
                enabled: false, canGoTo: false, canSplit: false, isSplitAtPlayhead: false,
                setIn: {}, setOut: {}, toggleSplit: {}, goTo: {})
        }
    }
}

private struct CutEditorMarkingMenu: View {
    @ObservedObject var model: CutEditorModel

    var body: some View {
        MarkingMenuItems(
            enabled: model.canStep, canGoTo: true, canSplit: model.canToggleSplit,
            isSplitAtPlayhead: model.isSplitAtPlayhead,
            setIn: model.setIn, setOut: model.setOut, toggleSplit: model.toggleSplit,
            goTo: { model.isShowingJump = true })
    }
}

private struct MarkingMenuItems: View {
    let enabled: Bool
    let canGoTo: Bool
    let canSplit: Bool
    let isSplitAtPlayhead: Bool
    let setIn: () -> Void
    let setOut: () -> Void
    let toggleSplit: () -> Void
    let goTo: () -> Void

    var body: some View {
        Button("Set In Point") { setIn() }
            .keyboardShortcut("[", modifiers: [])
            .disabled(!enabled)
            .accessibilityIdentifier("menu.marking.setIn")
        Button("Set Out Point") { setOut() }
            .keyboardShortcut("]", modifiers: [])
            .disabled(!enabled)
            .accessibilityIdentifier("menu.marking.setOut")

        Divider()

        Button(isSplitAtPlayhead ? "Remove Split at Playhead" : "Split at Playhead") { toggleSplit() }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!canSplit)
            .accessibilityIdentifier("menu.marking.split")

        Divider()

        Button("Go To…") { goTo() }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!canGoTo)
            .accessibilityIdentifier("menu.marking.goTo")
    }
}
