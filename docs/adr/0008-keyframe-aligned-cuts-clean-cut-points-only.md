# Keyframe-aligned cuts copy only at clean cut points, via the ffmpeg segment muxer

Engine Milestone 1 (keyframe-aligned cuts, pure stream-copy + concat) restricts cut points to
**clean cut points** — keyframes with no leading pictures depending across the cut — and produces
each segment with the ffmpeg **segment muxer**. A clean cut keeps the project's frame-accuracy
guarantee absolute: a stream-copy cut either lands frame-exact or is not offered. Cuts on
open-GOP keyframes are deferred to Milestone 2 (boundary re-encode, ADR-0004).

## Context: not every keyframe is a clean cut point

A keyframe is normally a safe stream-copy anchor, but **open-GOP** keyframes (HEVC CRA, many
MPEG-2 GOPs) are followed by *leading pictures* — frames that display before the keyframe but
decode after it and reference the previous GOP. A pure stream-copy cut at such a keyframe cannot
carry those frames: they either lose their reference (corrupt) or are dropped (frame-short). So
"keyframe-aligned ⇒ clean copy" holds only for **closed-GOP / IDR** keyframes.

This was confirmed in the shell against the three real test formats:

| Content | Cut points | Pure-copy result |
|---------|-----------|------------------|
| H.264/MP4 (Eurosport) | all closed-GOP | frame-exact, clean |
| MPEG-2/TS (BBC broadcast) | closed | frame-exact, clean |
| HEVC/MKV (MotoGP 2026) | mixed | clean-decoding but −1–2 frames at open-GOP boundaries |

A matching frame *count* is not sufficient proof; the open/closed distinction must be derived
from decode-vs-presentation order and is authoritative only when the cut segment actually decodes
without reference errors. A naïve PTS-reorder heuristic over-flags MPEG-2 and must not be trusted
on its own.

## Decision details

- The frame index gains a per-frame **clean-cut-point** flag (closed-GOP keyframe), in addition
  to the existing keyframe flag (ADR-0006). Only clean cut points are valid M1 in/out anchors.
- The cut-editor snaps a requested in/out point to the **nearest clean cut point** (refining the
  earlier "snap to nearest keyframe" intent).
- Segments are cut with:
  `ffmpeg -i <src> -map 0:v:0 -c copy -f segment -segment_times <t…> -reset_timestamps 1 out_%03d.<ext>`
  where each `segment_time` is the **midpoint between the target cut-point's PTS and its preceding
  frame's PTS**. The midpoint avoids a float `>=` boundary case in the segment muxer that
  otherwise bumps the cut to the *next* keyframe.
- Correctness is verified by **frame count against frame-index positions** plus a **decode check**
  (`-xerror`), never by reading the (reset) output timestamps.

## Consequences

- On open-GOP-heavy footage (the broadcast MPEG-2/TS and HEVC workload) the user has fewer M1 cut
  points to choose from. Frame-exact cuts at the remaining (open-GOP) points require Milestone 2.
- Input `-ss`/`-to` stream-copy seeking was rejected for the cut primitive: it landed
  inconsistently (HEVC undershot a full GOP; TS overshot ~1.9 s from its non-zero `start_time`).
  The segment muxer cuts reliably at keyframes regardless of format.
