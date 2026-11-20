# Build a per-clip frame index on import

On import, each clip is indexed with a fast `ffprobe` packet pass that records every frame's
timestamp and keyframe flag, cached in the project. This makes frame-number ↔ timestamp lookups
correct even for variable-frame-rate or telecined MPEG-2 TS — the exact target content — where
the cheap `N ÷ fps` assumption maps to the wrong frame and silently breaks frame accuracy. The
keyframe flags also feed the keyframe-aligned cut logic (engine Milestone 1).

## Consequences

- A one-time background indexing pass (shown with a progress indicator) runs on each import.
- The cost is accepted as the price of correctness on the target content; the index is cached
  so reopening a project is instant.

## Amendments (runtime cache, all-streams scan, and lookup invariants)

- **Runtime-only cache, rebuilt on reopen:** `frameIndexCache` is kept in memory on
  `ProjectDocument` rather than serialized into `.clipstitcher` JSON; reopening a saved project
  rebuilds indexes asynchronously in the background (throttled like import) alongside
  `containerStartCache`.
- **Single-pass all-streams streaming scan (issues #45, #81, #84):** Import runs one
  `ffprobe` packet scan (`FrameIndexer.scanAllStreams`) over audio + video streams (dropping
  sparse TS teletext/data streams that would look like false damage gaps), streaming stdout
  through `LineAssembler` so multi-hour files never materialize huge strings or temp files.
  The lowest-numbered video stream builds the canonical `FrameIndex` via `makeIndex` so frame
  counts, cut-editor positions, copy-share splits, and damage detection never disagree. Scan
  progress tracks `(runningMaxPts - firstPts) / duration` to normalize arbitrary TS clock
  offsets.
- **PTS↔DTS refill & CSV quirk:** Missing packet PTS is filled from DTS (and vice versa) so
  every decoded frame occupies one index slot; only packets lacking both are skipped. Trailing
  commas emitted by ffprobe's CSV writer on MPEG-2 streams are stripped at parse time.
- **Headless lookup contract:** `FrameIndex.keyframeIndex(atOrBefore:)` returns `nil` (never
  `0`) when no keyframe exists in `[0, n]`, forcing callers to decide degraded behavior
  explicitly rather than silently anchoring on a non-keyframe.
