# UI automation

How agents locate and drive the running app over the macOS accessibility (AX) API.
The probing process needs Accessibility permission (`AXIsProcessTrusted()` must be
true for it — the terminal hosting the session already has it on this machine).

## Accessibility identifiers (issue #5)

Stable `accessibilityIdentifier` values, readable as `AXIdentifier` on the AX tree.
Naming scheme: `<area>.<control>` — keep new controls consistent with it.

### Sidebar navigation (`RootView`)

| Identifier | Element |
| --- | --- |
| `nav.source` | Source section item |
| `nav.output` | Output section item |
| `nav.preview` | Preview section item |

The identifier lands on the row's static text. To switch sections externally, walk
up from the matched element to its `AXRow` ancestor and set `AXSelected = true`
(plain `AXPress` is not supported on the static text).

### Output view (`OutputView`)

| Identifier | Element |
| --- | --- |
| `output.mode` | Mode popup |
| `output.rendering` | Rendering popup (only present in Separate mode) |
| `output.type` | Type popup |
| `output.container` | Container popup (absent for audio-only type) |
| `output.export` | Export… button |
| `output.exportBlockedReason` | Why Export is disabled (issue #78); present only while clips are still analysing or a clip failed import/is source-missing — an `AXStaticText`, full reason in `AXValue` |
| `output.reencodeWarning` | Re-encode dominance warning (issue #15); present only when > 50 % of the planned output duration re-encodes — an `AXStaticText`, full warning text in `AXValue` (not `AXValueDescription`) |
| `output.status` | Export outcome (done / failed / cancelled); absent while idle or running |

For `output.status` the readable text is its accessibility value: done is
`"Export complete."` plus any warnings joined with spaces; failed is the error
message; cancelled has no value, only the visible label.

### Source view (`SourceView`)

Action panel buttons:

| Identifier | Button |
| --- | --- |
| `source.addFile` | Add File |
| `source.moveUp` | Move Up |
| `source.moveDown` | Move Down |
| `source.duplicate` | Duplicate |
| `source.delete` | Delete |
| `source.clear` | Clear |
| `source.audioSettings` | Audio Settings… |
| `source.setTarget` | Set as Target Clip |
| `source.relink` | Relink… |
| `source.clipDoctor` | Clip Doctor… (enabled for a single clip with a video damage zone, field-coded included) |
| `source.clipDoctorBlockedReason` | Why Clip Doctor is disabled for the selection (issue #83); present only when the single selected clip is audio-only (import failed "No video track") — an `AXStaticText`, "Clip Doctor repairs video sources only." in `AXValue` |

Clip Doctor banner (issue #55) — a non-modal suggestion above the timeline, present
only while a freshly-detected damaged clip has an undismissed suggestion:

| Identifier | Element |
| --- | --- |
| `source.doctorBanner` | The banner container |
| `source.doctorBanner.open` | Clip Doctor… button — selects the clip and opens the sheet |
| `source.doctorBanner.dismiss` | The × dismiss button |

### Clip Doctor sheet (`ClipDoctorView`, issue #53)

Opened from `source.clipDoctor` or the banner. Controls vary by phase (configuring →
running → finished):

| Identifier | Element |
| --- | --- |
| `clipDoctor.sheet` | The sheet container |
| `clipDoctor.destination` | Repaired-copy path (`AXStaticText`, full path in `AXValue`) |
| `clipDoctor.change` | Change… destination button (configuring only) |
| `clipDoctor.destinationError` | Why the picked/default destination is invalid (issue #83); present only when the destination denotes the source or its folder isn't writable — an `AXStaticText`, message in `AXValue`. While shown, `clipDoctor.repair` is disabled |
| `clipDoctor.omitted` | Notice listing non-AV streams not carried (present only when the source has any) |
| `clipDoctor.reencodeNotice` | Field-coded (PAFF) re-encode warning + time estimate (present only for a field-coded source; message in `AXValue`) |
| `clipDoctor.reencodeOptIn` | Toggle that must be on before Repair enables, for a field-coded source (issue #54) |
| `clipDoctor.repair` | Repair / **Replace** button (label is Replace when the destination already exists; disabled until `clipDoctor.reencodeOptIn` for a field-coded source) |
| `clipDoctor.progress` | Determinate progress bar (running only) |
| `clipDoctor.eta` | Time-remaining label beside the progress percent (running only, once estimable; text in `AXValue`) |
| `clipDoctor.cancel` | Cancel button (running **or** verifying). Cancels the live engine at once. Before the repaired file lands → configuring, nothing written; during the verify pass → finished with a "not verified" verdict, the output kept (issue #82); during a Verify Now re-scan → leaves the not-verified verdict |
| `clipDoctor.verdict` | The verdict headline (finished only; full message in `AXValue`). Outcomes: re-scanned clean / zones remain / inconclusive (re-scan failed) / **not verified** (verify was cancelled — see `clipDoctor.verifyNow`) |
| `clipDoctor.verifyProgress` | Determinate progress bar for a Verify Now re-scan (verifying only; replaces the verdict while it runs) |
| `clipDoctor.status` | Failure message (failed only; message in `AXValue`) |
| `clipDoctor.reveal` | Reveal in Finder (finished only) |
| `clipDoctor.verifyNow` | Verify Now button — re-runs verification on the kept output (finished only, present only when the verdict is "not verified", i.e. a cancelled verify — issue #82) |
| `clipDoctor.useRepaired` | Use Repaired File in This Project — relinks the clip (finished only) |
| `clipDoctor.done` | Done (finished only) |

A headless run needs no panel: the destination defaults to the `_repaired` sibling, so
`source.clipDoctor` → `clipDoctor.repair` → poll for the sibling file → read
`clipDoctor.verdict`. For a **field-coded** source, toggle `clipDoctor.reencodeOptIn` on
first — `clipDoctor.repair` is disabled until then. Over the raw AX API `AXValue` text reads
back via `AXValueDescription`, as with the row badge.

Clip rows: `source.clip.<index>` (0-based timeline order) is an AX *container*
(`AXGroup`) — its children keep their own identifiers. Each row's role badge is
`source.clip.<index>.role`; the verdict text (`Target` / `Smart render` /
`Re-encode` / `Cut only`) is exposed as the badge's accessibility value — over the
raw AX API it reads back via `AXValueDescription`, not `AXValue`. A clip with no
verdict (no target set, video unprobed) has no badge element at all. These exact
strings are pinned by `ClipRoleTests.badgeTextMatchesTheVisibleStrings`.

Each row's planned copy/re-encode split (issue #15) is `source.clip.<index>.share`;
the readable text (e.g. `92% copied`, `0% copied`) is its accessibility value (read
via `AXValueDescription`, like the badge). Absent until the clip's frame index is
built (import still running, or source missing).

## Modal-panel bypass (issue #37)

System file dialogs can't be driven reliably, so a launch-gated bypass skips them.
Defined in one place: `Sources/App/AutomationOverrides.swift`. Launch the app with
the marker plus the paths the run needs:

| Variable | Meaning |
| --- | --- |
| `CLIPSTITCHER_AUTOMATION=1` | Arms the bypass — must be exactly `1`; without it the panels behave as in normal use and the bypass is unreachable |
| `CLIPSTITCHER_EXPORT_DEST` | Export… destination — a file path in Connect mode (the mode's extension is appended if missing), a folder in Separate mode |
| `CLIPSTITCHER_IMPORT_SOURCE` | Add File sources — newline-separated paths, imported in order |
| `CLIPSTITCHER_RELINK_SOURCE` | Relink… source — a single path |

The bypass replaces only the panel; everything downstream (import pipeline, export
status/warnings/verification) runs exactly as in normal use. A companion variable
left unset leaves that flow on its panel. The environment is read once at launch.

Example — full headless loop (export, then re-import the result on a second launch):

```sh
CLIPSTITCHER_AUTOMATION=1 \
CLIPSTITCHER_IMPORT_SOURCE="$HOME/Downloads/clip.mkv" \
CLIPSTITCHER_EXPORT_DEST=/tmp/out.mp4 \
open --env-keep-all /path/to/ClipStitcher.app   # or launch the binary directly
# then over AX: press source.addFile → wait for the row → nav.output → output.export
# → poll /tmp/out.mp4 → read output.status
```

(`open` strips the environment unless the binary is launched directly —
`…/ClipStitcher.app/Contents/MacOS/ClipStitcher &` is the reliable way.)

## Synthesized-event gotchas (issue #41)

- **Esc doesn't fire SwiftUI's `.cancelAction`** when posted as a synthesized
  CGEvent keyboard event, even with the window reported as `AXFocusedWindow` —
  a real keyboard works fine (human-verified). Other shortcuts (Space, ⌘J) and
  popover dismissal do respond to synthetic keys. Close dialogs/windows by
  AX-pressing their Cancel/OK buttons instead.
- **Shift-flag latching**: posting an event with `flags = .maskShift` alone
  latches Shift into the combined event-source state, corrupting every later
  synthesized event. Bracket shifted events with real Shift keydown/keyup
  (virtual key 56).
- **Direct binary launch shows the document Open panel** (no auto-untitled
  document) — press its `NewDocumentButton`. A relaunch may instead restore
  the previous document with its clips; don't assume a clean slate.
- **Key presses reach a List's `onKeyPress` only when that list is the focused
  element** — window focus is not enough (issue #42). Set `AXFocused = true` on
  the list's `AXOutline`; the Source window has two outlines (sidebar nav and
  clip list), so pick the one whose descendants carry `source.clip.*` ids.
- **`kAXParentAttribute` reads back nil on the clip-row `AXGroup`s** over the raw
  AX API, so the walk-up-to-`AXRow` trick (sidebar section) fails there. Find rows
  top-down instead: collect elements with role `AXRow`, match by their static-text
  contents, then set `AXSelected` on the row (issue #42).

## Probe recipe

A minimal external probe (Swift script, no project needed):
`AXUIElementCreateApplication(pid)` for bundle id `io.github.raykennedy777.clipstitcher`,
then recurse `AXChildren` from `AXWindows` collecting `AXIdentifier`. AppleScript's
`entire contents of window 1` still reports 0 for SwiftUI content — use AXChildren
traversal instead; it returns the full annotated tree.
