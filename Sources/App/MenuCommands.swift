import SwiftUI

// Menu-bar commands for the frame surfaces (issue #67): a Playback menu (Play/Pause,
// Step, Keyframe, Scene) and a Marking menu (Set In/Out, Split, Go To…). These make the
// shortcuts discoverable where macOS users look for them (HIG), and carry the ⌘J / ⌃⌘S
// routing that the cut-editor's hidden buttons used to.
//
// Routing: the output preview lives in the document scene, so it publishes a
// `previewTransport` focused value while it's key. The cut editor is a separate
// top-level window outside that scene, so it can't; its key window publishes its model
// through `ActiveCutEditor` instead (see that type). The two are mutually exclusive — a
// cut-editor window being key resigns the document scene — so each menu reads the cut
// editor first, then the preview. Cut-editor-only actions (Scene, all of Marking) show
// disabled when no cut editor is key.
//
// The transport buttons inside each window keep their own `.keyboardShortcut`s; while a
// window is key those key-window-local equivalents handle the keystroke (the same
// window-before-menu ordering #89 relied on), so the menu never double-fires — and both
// paths call the same model method regardless, so even a menu-first match is a single,
// correct action. For the retired ⌘J / ⌃⌘S buttons the menu is now the only path, and it
// routes to the key cut-editor's model.

// MARK: - Preview transport (document-scene focused value)

/// The output preview's transport, published as a focused scene value while the preview
/// is key so the Playback menu can drive it (issue #67). The preview shares Play/Pause,
/// frame stepping, and keyframe stepping with the cut editor; it has no scene scan.
struct PreviewTransport {
    let isPlaying: Bool
    /// A frame is loaded and steppable (not still building the index / empty).
    let canStep: Bool
    let togglePlay: () -> Void
    /// ±1 frame.
    let step: (Int) -> Void
    /// Previous (−) / next (+) keyframe anchor.
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

// MARK: - Playback menu

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

/// The Playback items bound to the key cut-editor. A dedicated `@ObservedObject` view so
/// the menu re-evaluates as the model's `isPlaying` / `canStep` / scene-scan state change
/// (an app-level `@ObservedObject` on `ActiveCutEditor` only sees the model swap).
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
    /// Scene scanning is cut-editor-only; the preview passes false so its items disable.
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

// MARK: - Marking menu (cut-editor only)

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
    /// Go To (⌘J) is enabled whenever a cut editor is key — no `canStep`/indexing gate — so it
    /// matches the timecode-readout tap, which opens the jump popover unconditionally.
    let canGoTo: Bool
    /// A split at the playhead is only valid strictly inside the selection range.
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
