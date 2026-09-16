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
| H.264/MP4 (broadcast) | all closed-GOP | frame-exact, clean |
| MPEG-2/TS (broadcast) | closed | frame-exact, clean |
| HEVC/MKV (broadcast) | mixed | clean-decoding but −1–2 frames at open-GOP boundaries |

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
  - **Amended (issue #2):** for **mpeg2video into MKV** (cut and whole-clip remux alike) the copy
    additionally carries `-bsf:v setts=pts=if(eq(PTS\,NOPTS)\,DTS\,PTS)`. Real MPEG-PS broadcast
    captures contain occasional packets with no PTS at all (the second frame of each
    duplicated-timestamp anomaly); TS and MP4 tolerate them, matroska refuses ("Can't write
    packet with unknown timestamp") — even on a plain whole-file remux, so this was never about
    the joins. The filter refills exactly those packets' PTS from DTS — the same rule
    `FrameIndexer.parseIndex` uses to number frames (ADR-0006) — and is the identity on
    fully-stamped sources. Every other codec×container command is byte-identical to its
    validated shape. De-risked on the real broadcast capture end-to-end (cut, re-encode, concat,
    chained remux, audio mux — frame-exact, clean decode, verify gates pass).
  - **Amended 2026-09-16 (issue #116):** the same runs also carry `-fflags +genpts` on the
    **input**, and the `setts` filter above is now the fallback behind it. An MPEG-PS PES packet
    carries one timestamp, so the second access unit packed into one PES loses its PTS — and
    that one is an **anchor** (I or P) picture, whose PTS leads its DTS by the reorder delay.
    Refilling it from its own DTS put it `bf` frames early, on the previous anchor's PTS, and
    the finished MKV piece then failed the verify decode ("non monotonically increasing dts to
    muxer") although its pictures were correct. `+genpts` makes the demuxer derive the true
    reordered PTS instead. It fills only packets that have no PTS, so a fully-stamped source is
    unaffected: MPEG-2, H.264 and HEVC `.ts`→`.mkv` copies come out with identical packet
    timestamps and identical framecrc, and the `-ss` landing of ADR-0027 does not move.
    `setts` stays in the chain for any packet `+genpts` still cannot resolve, which is the
    damaged-source guarantee of ADR-0020.
  where each `segment_time` is the **midpoint between the target cut-point's DTS (decode time) and
  the DTS of the packet decoded immediately before it**. The segment muxer splits at the first
  keyframe whose **decode** time is `>=` the requested time, so the value must be derived from DTS,
  not PTS. The midpoint sits safely below the cut-point's DTS, avoiding a float `>=` boundary case
  that otherwise bumps the cut to the *next* keyframe.
  - **Correction (de-risked in the shell after the original PTS-based recipe):** on B-frame streams
    a keyframe's PTS is later than its DTS, so a PTS-based midpoint can land *after* the keyframe's
    DTS and make the muxer skip it. This was caught on the H.264/MP4 clip — the primary format —
    where a PTS-midpoint cut jumped a full keyframe (a 50-frame segment came out 89). The DTS-based
    midpoint cuts frame-exact across all three formats. The frame index therefore carries DTS
    alongside PTS, and `FrameIndex.segmentTime(forCutAt:)` computes the DTS midpoint. (With no
    B-frames the two coincide.)
- **Clean-cut-point detection is codec-specific** (no decode needed; read the bitstream headers via
  the `trace_headers` bitstream filter, correlating keyframe NAL/picture units 1:1 with keyframe
  packets in decode order):
  - **MPEG-2** — every keyframe (I-frame) is a clean cut point. Even `closed_gop=0` GOPs cut
    frame-exact (the leading B-frames reference the *previous* GOP, which a kept segment retains).
    This is why the naïve PTS-reorder heuristic over-flags MPEG-2 and must not be used.
  - **H.264** — IDR keyframes (NAL type 5) are clean.
  - **HEVC** — IDR (NAL 19/20) is clean; **CRA (21) / BLA (16–18) are not** — their RASL leading
    pictures reference the keyframe itself, so a copy cut at a CRA boundary drops/adds 1–2 frames
    (verified: a CRA-to-CRA extraction came out ±1–2 frames).
- Correctness is verified by **frame count against frame-index positions** plus a **decode check**
  (`-xerror`), never by reading the (reset) output timestamps. A third check inspects the output's
  presentation timestamps (`ExportEngine.timestampDefect`). This is *not* "reading the reset
  timestamps to confirm a cut landed right" (still forbidden) — it asserts the piece's timestamp
  health, catching the two concat-mux defects below.
  - **Amended (issue #19):** the check's original premise — one piece, one source, constant frame
    rate ⇒ uniform spacing — is false for **faithful stream copies of a timestamp-irregular
    source**. The real 2009 broadcast capture carries ~714 duplicate-PTS + re-sync-gap
    anomalies in 67 min; a copy span covering one reproduces it bit-exact, and the uniformity
    check rejected (and deleted) correct exports. The gate is now **plan-aware**: inside a
    **copied** span, an anomaly is a defect only if the source has no anomaly of the same kind
    (duplicate vs gap) within **±3 frame intervals** of the corresponding source position;
    **re-encoded** spans, the **seam intervals** between segments, and a **2-interval window** at
    every segment edge keep strict uniformity — that is where the shipped defect classes
    (start_time seam gap, B-pyramid/MKV PTS collapse, MP4 timescale squeeze) live. An anomaly the
    source has that the output *lacks* is never a defect (containers may normalize). The ±3
    radius is measured, not guessed: the mpegts mux round-trip surfaces the second frame of a
    source duplicate with no PTS at all, the frame indexer refills it from DTS (ADR-0006), and
    that re-materializes the anomaly displaced by up to the stream's B-frame reorder depth
    (displacement 2 observed on the real MPEG-2 fixture; ±1 — the first guess — spuriously
    failed it). Consequence of seam strictness: a source anomaly that happens to sit *at* a
    planned segment boundary still fails verification — conservative by design; the shell
    de-risk caught a real misplaced-seam defect at exactly that position, so loosening seams
    would have shipped it. De-risked on MPEG-2/TS (dirty broadcast end-to-end pass + clean-CFR
    no-regression + injected dup/gap still fail), H.264/MP4 and HEVC/MKV+MP4 (clean
    copy+re-encode+concat pass both old and new gate). A full re-encode (`ConformEngine`) keeps
    the plain uniformity check — there is no copied span to be faithful to.
  - **Amended (issue #47 / ADR-0020):** the strict 2-interval edge window no longer applies at the
    piece's **outermost** edges (the first segment's head, the last segment's tail) — nothing abuts
    them within the piece, and a whole-file copy faithfully reproduces the source's own tail
    anomaly (the `-t`-cut HEVC fixture presents a B-pyramid hole in its final interval; the old
    gate made such sources unexportable). The source-match requirement still applies there, and
    interior seams stay strict. The frame-count gate also gains damage awareness — repaired
    segments expect their slot budget, short only inside an EOF damage window (ADR-0020).

## Consequences

- On open-GOP-heavy footage (the broadcast MPEG-2/TS and HEVC workload) the user has fewer M1 cut
  points to choose from. Frame-exact cuts at the remaining (open-GOP) points require Milestone 2.
- Input `-ss`/`-to` stream-copy seeking was rejected for the cut primitive: it landed
  inconsistently (HEVC undershot a full GOP; TS overshot ~1.9 s from its non-zero `start_time`).
  The segment muxer cuts reliably at keyframes regardless of format.
- **The non-zero `start_time` also opened a seam gap when the pieces were concatenated** (de-risked
  in the shell on all three formats). A head-**copy** piece is segment 0 of the cut, which
  `-reset_timestamps` does *not* rebase, so it keeps the source's `start_time` (Jerez 0.040,
  MPEG-2 .mpg 0.24). On MKV/MP4 the container duration field measures from zero and so *includes*
  that leading offset; the concat demuxer advances the timeline by that inflated duration and places
  the following (re-encode) piece one frame-slot late → a gap at the copy→re-encode seam. TS is
  immune — the mpegts muxer's default `initial_offset` (~1.44 s) shifts every piece uniformly, so
  the naive concat is already gap-free there. **Fix:** the concat list carries a `duration`
  directive per piece = `pts[upperBound] − pts[lowerBound]` of its kept frames (an exact
  presentation-time span — no frame-rate estimate, so the demuxer cannot truncate), which overrides
  the container duration and closes the gap. Container-agnostic: on a `start_time` ≈ 0 source the
  directive equals the real span and is a no-op (verified). See `ExportEngine.concatListContents` /
  `BoundaryReencodeEngine.segmentSpans`. *(The cross-clip concat carried the same risk for a
  single-copy-segment piece that keeps the source's `start_time`; fixed the same way via
  `ExportEngine.clipSpans` — issue #6. The cross-clip de-risk narrowed the biting conditions: a
  whole-clip plain remux normalises `start_time` to 0 in every container, so only the segment-muxer
  piece with no head cut keeps it; and the inflated-duration gap showed in **MKV only** — the MP4
  pieces' duration matched the true span and the directive was a verified no-op there, unlike the
  within-clip observation above.)*
