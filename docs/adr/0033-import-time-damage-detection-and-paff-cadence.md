# Import-time damage detection and field-coded (PAFF) cadence detection

Reception dropouts in live broadcast captures leave corrupted byte spans and truncated endings
that corrupt downstream smart renders unless surfaced at import (issues #45, #80). Meanwhile,
field-coded (PAFF) captures store ~2 packets per displayed frame, throwing off packet-based
frame indexing by 2× unless identified at import (issue #46).

A naive from-start full decode cannot be used for damage detection: on non-IDR recovery-point
streams, decoder corrupt flags avalanche across clean frames (measured at 43% of frames on a
clean real broadcast capture, pixel-identical to fresh seeks).

## Decision

### Three-stage damage detection (`DamageDetector`)

1. **Stage 1 — Demux anomaly pass over the all-streams packet scan.**
   - Video cadence runs on **DTS in demux order** (PTS reordering hides holes behind B-frames).
   - Packets with `dts == nil && pts != nil` are treated as Matroska's benign head placeholders
     and ignored (splicing PTS into DTS fabricates a false gap + duplicate pair at the file
     head). Packets with `dts == nil && pts == nil` are recorded as truncated pictures timed at
     the last seen timestamp.
   - Containers with almost no DTS fall back to sorted PTS for **gap detection only**; the
     duplicate-timestamp rule remains DTS-exclusive because sorted PTS legitimately duplicates
     on dirty broadcast streams.
   - Audio PTS gaps are included alongside video anomalies because real broadcast dropouts
     often carry companion audio gaps even where video packets show no gap.
   - **Two-band video gap detection (issue #80):** Sharp holes trigger at
     `delta >= 1.8 × max(globalMedian, localMedian)` (`window = 201`). Including the local
     median prevents a permanent cadence drop (such as a Clip Doctor PAFF copy-head → MBAFF
     tail splice) from flooding the tail with false gaps; taking `max(global, local)` prevents
     a duplicate-DTS burst from collapsing the local median below the global baseline.
     Sustained slow runs (`>= window / 2` deltas exceeding `1.8 × global` while suppressed by
     `local`) emit a candidate **only** when bounded and returning to baseline cadence
     (`< 1.8 × global`) before EOF.
   - Duplicate-DTS bursts trigger at `delta <= 0.25 × median`. Adjacent anomalies within 2.0 s
     merge into one candidate cluster.

2. **Stage 2 — Seek-anchored windowed confirm decodes.**
   - Each candidate cluster is confirmed by seeking **2 keyframes back** (1 GOP margin + 1 GOP
     for MPEG-PS byte-estimated seek slack) and decoding with `-vf showinfo` into a temp stderr
     file (bypassing `ProcessRunner`'s bounded stderr tail).
   - Both the decode duration and the judged damage-span window share one `tailLookahead = 1.5 s`
     so late-resume holes pushed past the candidate end by MPEG-PS seek slack are both decoded
     and judged.
   - Corrupt/error lines (`corrupt decoded frame`, `Error submitting packet to decoder`) print
     *before* the affected frame's `Parsed_showinfo` line. Corrupt frames outside the candidate
     window are ignored so early MPEG-PS seek landing artifacts do not contaminate the verdict.
   - Decoded holes are judged against the decoded **clean-margin** frame interval
     (`marginInterval`), never the packet-index cadence (which is 2× off on PAFF) and never the
     damaged interior (which can emit garbled half-interval frames).
   - **Authority rule:** A clean confirm decode (frames decoded, no damage span) vetoes a
     **gap-only** video anomaly (degrading it to an audio-only zone if a companion audio gap
     exists, or dropping it otherwise). Opaque demux evidence (duplicate-DTS bursts,
     timestamp-less packets) is never vetoed by a clean decode because decoders silently absorb
     it. A zero-frame confirm decode (`decodedFrameCount == 0`) never vetoes a video candidate.

3. **Stage 3 — Last-GOP EOF check (truncated endings).**
   - Seeks **3 keyframes back** from the end of the file to catch a truncated final frame that
     leaves no inter-packet gap.
   - Deliberately runs **no PTS-hole check** at EOF because legitimately `-t`-cut B-pyramid
     tails present missing tail slots while DTS is clean.
   - Dropped-final-frame threshold is `0.75 × localInterval` so a PAFF source's final second
     field (`0.5 × interval` past the last decoded frame) does not false-trigger.

### Field-coded (PAFF) cadence detection (`FieldCodingDetector`)

- Measured from the **median** interval of sorted `packetPts` (requiring `>= 25` intervals so
  isolated broadcast timestamp anomalies cannot skew it — median, never mean).
- Compared against `min(avg_frame_rate, r_frame_rate)` as the display rate: true PAFF captures
  probe `avg_frame_rate` at the 2× field rate and `r_frame_rate` at the display rate, while
  frame-coded MBAFF files sometimes exhibit the inverse quirk (`r_frame_rate` at 2× field rate
  over 1 packet/frame). Taking `min` handles both simultaneously.
- Flagged when `abs(packetsPerFrame - 2.0) <= 0.3`.

## Consequences

- Import-time detection runs in seconds even on multi-hour captures and avoids false-positive
  avalanches on non-IDR streams.
- Repaired PAFF-head / MBAFF-tail outputs from Clip Doctor re-scan cleanly without false gap
  floods on the cadence transition.
- `MediaProbe.Result` keeps `r_frame_rate` (`videoCodecFrameRate`) alongside
  `VideoProperties.frameRate` so both rate candidates reach `FieldCodingDetector`.
