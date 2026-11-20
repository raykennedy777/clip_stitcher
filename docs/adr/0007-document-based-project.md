# Document-based project model (DocumentGroup)

A project is a macOS document (`.clipstitcher`) managed by SwiftUI's `DocumentGroup`, rather than
a single-window app with hand-rolled save/load. This yields HIG-correct Open / Save / Save As /
Duplicate / Recents / multiple-windows / unsaved-changes tracking essentially for free. The
document stores *references* to source media as bookmarks, plus each clip's
in/out range, the target-clip selection, and the output settings —
never the media itself.

## Amendments (runtime state, schema evolution, and readiness)

- **`ReferenceFileDocument` with runtime-only caches:** `ProjectDocument` uses
  `ReferenceFileDocument` so async import/probe/index tasks can mutate `@Published` state. Only
  `VidProject` JSON is persisted; `importStates`, `urlCache`, `frameIndexCache`,
  `containerStartCache`, and `lastViewedFrames` are runtime-only.
- **Unsandboxed preferences (issue #87):** Consistent with outside-App-Store distribution
  (ADR-0002), the app has no App Sandbox entitlement, so app-wide settings such as the fixed
  export folder live as plain paths in `UserDefaults` (`AppSettings` / `ExportPanelDefaults`).
- **Backward-compatible `.clipstitcher` JSON evolution:** Every newly added field decodes via
  `decodeIfPresent ?? default`, legacy keys (such as `audioSelections`) keep their original
  JSON names, and `AudioTrackSlot` decodes both its `{selection, mix}` object and pre-ADR-0019
  bare `AudioTrackSelection` payloads.
- **Import readiness gate & reopen re-import (issue #78):** A clip with a resolvable bookmark
  but `video == nil` (e.g., autosaved mid-probe) resolves on reopen to `.reimport`, never
  `.ready`. Export is gated on every clip being ready, and `ExportPlanner.videoTreatment`
  refuses `video == nil` as a hard backstop so an unprobed clip can never fall through to
  `EncoderSelection`'s libx264 default.
- **Read-only Clip Inspector (issue #88):** `ClipInspectorView` performs zero additional media
  probing (reading only cached `Clip` metadata + filesystem stat) and derives its match verdict
  solely from `MatchEvaluator.matchVerdict` / `differences`.
