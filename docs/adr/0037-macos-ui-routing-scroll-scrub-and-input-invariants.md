# macOS UI routing, input handling, scroll-scrubbing, snapshots, and reporting invariants

Building a native SwiftUI + AppKit video editor (ADR-0001, ADR-0007) exposed several macOS
platform behaviors and UX invariants that are non-obvious from reading individual views alone
(issues #15, #21, #67, #87, #89).

## Decision

### Out-of-scene cut-editor menu routing (`ActiveCutEditor`, issue #67)

- Cut-editor windows are standalone top-level `NSWindow`s outside SwiftUI's `DocumentGroup`
  scene, so `@FocusedValue` / `focusedSceneValue` cannot observe them.
- Menu-bar commands (`File ▸ Save Frame as Image…`, `Playback`, `Marking`) therefore pair two
  mutually exclusive channels: `@FocusedValue` (`\.saveFrame`, `\.previewTransport`) for
  in-scene surfaces (Output Preview) and an app-level `ActiveCutEditor` `ObservableObject` set
  by `CutEditorPresenter` on `windowDidBecomeKey` and cleared on resign/close.
- `ActiveCutEditor.resign(_:)` checks object identity (`self.model === model`) so a late resign
  cannot clear a newly activated editor, and `windowWillClose` resigns explicitly because
  AppKit can close a window without delivering `windowDidResignKey`.
- Every menu item driven by a cut-editor wraps `CutEditorModel` in a dedicated `@ObservedObject`
  child view (`CutEditorSaveFrameButton`, `CutEditorTransportMenu`, `CutEditorMarkingMenu`)
  because observing `ActiveCutEditor.shared` alone only re-renders on window swaps, not on the
  model's `@Published` state changes (`isPlaying`, `canStep`, `canSaveFrame`, etc.).
- `File ▸ Save Frame` (`⌃⌘S`, chosen because `⌘S`/`⇧⌘S` belong to `DocumentGroup`) and
  `Marking ▸ Go To` (`⌘J`, via `@Published isShowingJump`) route solely through menu commands;
  in-window transport buttons retain local `.keyboardShortcut`s relying on window-before-menu
  precedence so shortcuts stay discoverable without double-firing.

### SwiftUI / AppKit macOS input and presentation invariants

- **Arrow-key shortcuts ignore `.shift`:** SwiftUI matches arrow-key `.keyboardShortcut`
  equivalents while ignoring `.shift`, so registering separate `←` and `⇧←` shortcuts invokes
  the first button for both. Both `CutEditorView` and `PreviewView` register one shortcut per
  arrow key and branch on live `NSEvent.modifierFlags.contains(.shift)`.
- **macOS `List.onKeyPress` delete keys:** Backspace arrives as DEL (`"\u{7F}"`) rather than
  `.delete` (U+0008), and forward-delete carries `.function` in `press.modifiers`. Delete
  handlers match `["\u{7F}", .delete, .deleteForward]` and reject only chord modifiers
  (`[.command, .option, .control, .shift]`).
- **Single `.fileImporter` / distinct `.sheet` nodes:** Stacking multiple `.fileImporter` or
  `.sheet` modifiers on one SwiftUI view node silently breaks all but the last presenter.
  Multiple file-picker jobs multiplex through one `.fileImporter` + purpose enum, and multiple
  sheets attach to distinct nodes. Because `.fileImporter` clears `isPresented` *before*
  invoking its completion closure, target context (e.g., `browsingSlot`) is stored separately
  and cleared in `defer` inside the completion.

### Scroll-to-scrub (`.scrollScrub` + `ScrollScrubAccumulator`)

- SwiftUI has no scroll-wheel modifier, so `.scrollScrub` uses a transparent
  `NSViewRepresentable` (`hitTest` returns `nil`) installing a local `.scrollWheel` `NSEvent`
  monitor scoped to `event.window === window && bounds.contains(...)` — allowing the sidebar
  and popovers (separate windows) to scroll normally.
- Direction follows page semantics (positive `scrollingDeltaY` = backward) using
  system-adjusted deltas so Natural Scrolling needs no inversion.
- Because macOS redirects `Shift + mouse wheel` onto `deltaX`, non-precise wheel events with
  `shift && deltaY == 0` fall back to `deltaX`; horizontal scrubbing is otherwise ignored.
- Notched mouse wheels (`precise == false`) round `.awayFromZero` so sub-1.0 driver deltas
  never swallow a notch; trackpads (`precise == true`) accumulate fractional `carry` toward
  `pointsPerFrame`. Momentum/coasting events are ignored (playhead stops dead on finger lift
  while preserving `carry`), and the monitor consumes every hovered event (`return nil`) even
  when `steps == 0` so sub-threshold gestures never leak to underlying scroll views.

### Save Frame as Image (issue #89)

- Saves full-resolution PNGs at the source's **coded (storage)** dimensions (not SAR-corrected
  display pixels) with WYSIWYG deinterlacing parity: woven in the cut-editor, and `bwdif`
  deinterlaced in Output Preview iff the preview's conform chain deinterlaces that clip.

### Honest smart-render reporting (issue #15) and same-source batch gate

- Per-clip copied share rounds to whole percent but clamps any fraction `< 1.0` to **99%** so
  clips with boundary re-encodes never display as "100% copied".
- `OutputView`'s re-encode dominance warning appears only when `> 50%` of the planned output
  duration re-encodes, avoiding noise on closed-GOP boundary slivers.
- Multi-clip batch actions requiring one underlying source (Audio Settings, batch Relink) key
  clips by resolved standardized file URL first, falling back to raw bookmark bytes when
  unresolved so duplicated clips pointing at a missing file still satisfy the same-source gate.

## Consequences

- Menu commands, keyboard shortcuts, delete handling, file pickers, and scroll scrubbing behave
  consistently across both `DocumentGroup` windows and standalone cut-editor windows.
- UI code avoids duplicated SwiftUI presenter bugs and keeps pure step/reporting math
  unit-testable (`ScrollScrubAccumulatorTests`, `BatchSelectionTests`, `ExportPlannerTests`).
