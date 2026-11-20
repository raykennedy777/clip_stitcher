# Headless stitching is a CLI target, not GUI automation

Issue #105 needed scripts and agents to drive frame-accurate stitching without a
human: a job description in, an exported file out, failure modes a caller can branch
on. The repo already had one automation route — launching the app with the
`CLIPSTITCHER_AUTOMATION=1` marker-gated overrides (unreachable on normal launches;
companion env vars optional per flow) and driving it through the accessibility (AX)
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

**Amended 2026-09-16 (issue #115):** stdout has one exception — `clipstitch --plan
<job.json>`. That flag is a **query**, not a run: it stops after the probe/index/plan
half of `StitchPipeline`, writes no media, and prints the plan as one JSON document
(`PlanReport`, contract version 1, documented in docs/stitch-job.md). The rule the
original decision was protecting still holds, because the answer *is* the output: a
caller reads stdout whole, with no log parsing, and stage lines, warnings and the
verdict stay on stderr. `--plan job.json 2>/dev/null` is the JSON alone.

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

## CLI contract details

- **Argument parsing (`ClipStitchArguments`):** Options are accepted in any position; unknown
  `--*` tokens fail immediately with exit 64 (never treated as filenames); `--plan` refuses an
  output-path positional argument (signalling the caller expected a render).
- **Exit-code boundaries:** Missing source files fail pre-probe as invalid job (exit 65);
  readable audio-only files fail as probe errors (exit 66, matching GUI issue #83). Video
  outputs enforce matching destination extensions up front, whereas audio-only outputs skip
  pre-probe extension checks because the target's audio codec is unknown until probed.
- **Per-path source deduplication:** `StitchPipeline.prepare` probes and indexes each distinct
  source path once in first-appearance order.
- **Stderr error/verdict & timing contracts (issue #113):** Long error details are head+tail
  excerpted (`BoundedExcerpt`) unless `--verbose` is passed (usage errors always print whole;
  stdout stays silent regardless). Every run ends on stderr with one single-line verdict
  (`Done: …`, `Planned: …`, or `clipstitch: FAILED (<code label>): <summary>`) so `tail -1`
  reliably parses the outcome. `ExportError.verificationFailed` opens its payload with
  `VerificationLocation.line` (0-based `clips[]` index + piece filename + capped plan summary)
  as line 1 so the verdict reuses a single source of truth. `StageClock` / `segmentTimingLine`
  spellings are a pinned contract grepped by external slot logs.
- **`PlanReport` JSON invariants (issue #115):** Nullable fields are always serialized as
  explicit `null` (never omitted via `encodeIfPresent`); `videoOnly` outputs report 0 audio
  tracks; `copySafeKeyframes` reports conservative copy-start-safe keyframes bracketing
  `outFrame + 1` so any mark moved there is guaranteed copyable.
