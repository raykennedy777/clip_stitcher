# Headless stitching is a CLI target, not GUI automation

Issue #105 needed scripts and agents to drive frame-accurate stitching without a
human: a job description in, an exported file out, failure modes a caller can branch
on. The repo already had one automation route — launching the app with the
`VIDCONFORM_AUTOMATION` overrides and driving it through the accessibility (AX)
layer (docs/agents/ui-automation.md) — so the decision was whether headless
stitching rides that route or gets a real CLI. It gets a real CLI: a `clipstitch`
command-line target that reads a **Stitch Job** JSON (docs/stitch-job.md) and calls
the same engine layer the app calls.

## Decision

- A new `clipstitch` tool target compiles the app's engine layer — `Sources/Models`
  + `Sources/Services` — **as-is**, plus a thin `CLI/` entry point. No engine code is
  duplicated or forked: probing, indexing, field-coding detection, damage detection,
  audio resolution, planning, and export are byte-for-byte the app's
  (`StitchPipeline` orchestrates them exactly as `ProjectDocument` does, minus GUI
  state). The one excluded Services file is `FrameExtractor`, whose
  `FrameStreamDecoder` dependency is AppKit-side and which serves only preview
  surfaces.
- The job schema (`StitchJob`) is a Codable mirror of the project model with plain
  paths instead of security-scoped bookmarks, documented in docs/stitch-job.md as
  the public cross-repo contract.
- Failure classes map to exit codes (64 usage / 65 invalid job / 66 probe-index /
  70 export), stderr carries the humans' text, stdout stays silent.

## Why not the AX/automation route

- **The AX route needs a login session and screen.** It exists for *testing the
  GUI* — probing what a user sees, clicking what a user clicks. A locked screen
  blocks it (the headless-verification lesson), which disqualifies it as the
  foundation for unattended pipeline runs.
- **A GUI conversation is not a contract.** Driving the app through panels means
  encoding cut points and audio choices as UI gestures; every layout change breaks
  callers, and failures surface as timeouts staring at a window, not as typed
  errors. The Stitch Job JSON is versioned, validated, and refuses precisely.
- **The engine was already CLI-shaped.** The planning core is pure (`ExportPlanner`,
  ADR-0009/0011) and the engines are static async functions over URLs — the GUI is
  one caller among possible others by design. A CLI target is the thin second
  caller, not a second implementation.

## Consequences

- Engine changes serve both targets automatically; the CLI can never stitch
  differently than the app. The price is that `Sources/Models` + `Sources/Services`
  must stay AppKit/SwiftUI-free (true today; the tool target's build enforces it
  from now on).
- The CLI refuses job/source mismatches (out-of-range frames, missing audio
  streams) where the GUI reconciles interactively — reconciliation is an editing
  affordance; a script that asked for exact coordinates must get exactly those or
  an error (`StitchJobError`).
- Per-clip separate export, external audio files, and channel mixes stay out of the
  contract until something needs them; the schema is versioned so they can arrive
  without breaking version-1 callers.
