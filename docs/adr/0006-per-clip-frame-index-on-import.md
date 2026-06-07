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
