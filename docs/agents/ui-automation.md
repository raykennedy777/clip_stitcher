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

Clip rows: `source.clip.<index>` (0-based timeline order) is an AX *container*
(`AXGroup`) — its children keep their own identifiers. Each row's role badge is
`source.clip.<index>.role`; the verdict text (`Target` / `Smart render` /
`Re-encode` / `Cut only`) is exposed as the badge's accessibility value — over the
raw AX API it reads back via `AXValueDescription`, not `AXValue`. A clip with no
verdict (no target set, video unprobed) has no badge element at all. These exact
strings are pinned by `ClipRoleTests.badgeTextMatchesTheVisibleStrings`.

## Probe recipe

A minimal external probe (Swift script, no project needed):
`AXUIElementCreateApplication(pid)` for bundle id `com.conmotogroup.vidconform`,
then recurse `AXChildren` from `AXWindows` collecting `AXIdentifier`. AppleScript's
`entire contents of window 1` still reports 0 for SwiftUI content — use AXChildren
traversal instead; it returns the full annotated tree.
