# A copy segment's read starts at a *measured* seek landing, and the cut still places itself

A stream-copy segment is produced by the ffmpeg **segment muxer**, split at DTS midpoints the
frame index computes (ADR-0008). The muxer has no notion of "start here" — it opens the input
and writes *every* segment the split points imply. Two of those are throwaway: everything before
the in-cut, and everything after the out-cut.

The tail was bounded first (issue #107, output `-t`). That left the **head**, whose size is the
clip's in-point — the wrong axis for this app's workload, and the one that grows. A combined
Sunday recording is one 4h36 / 16.8 GB capture from which each class takes a later slice, so
every class discards more than the last. Measured on the real render (issue #108): one 54 s copy
150 min in wrote **8.6 GB** of pre-clip head for ~0.4 GB of wanted piece, moto2's six copy
segments discarded **37.8 GB** between them for a 2.9 GB output, and MotoGP's nine copy clips —
in-points from 150 to 259 min — projected to **~100 GB of throwaway for a ~5 GB output**. The
export directory peaked at 43 GB. Nothing leaked; this is render time and peak headroom.

## Context: why the obvious fix was wrong twice

**Seek to the span and drop the in-cut.** This is `.boundedKeyframe` (ADR-0021, issue #52),
which is frame-exact on a whole-file repair plan *because every copy boundary there is a
copy-safe keyframe by construction*. General joins do not qualify, and trying it anyway gave
**2501 packets instead of 2251** on open-GOP HEVC and an off-by-a-GOP first keyframe on H.264.
It also cuts with `-segment_frames`, a decode-order count, which cannot express the open-GOP end
where the copy range stops `n_leading` frames *before* the out-cut keyframe (issue #16). The
time-based cut exists precisely because those two differ.

**Predict where the seek lands.** The segment muxer measures `-segment_times` from **the first
packet it sees**, not from the file start — so an input seek silently moves every split by the
size of the head it skipped. Knowing the landing is therefore the whole problem, and the frame
index cannot supply it: on the real open-GOP HEVC capture, `-ss` at a keyframe's own pts landed
a **whole keyframe earlier** than asked, because Matroska's cues do not index every keyframe the
packet flags call one. A predicted origin ships a piece with the right frame count and the wrong
frames — no count-based gate sees it (verified: it survives them, and the mutation fails the
integration suite instead).

## Decision

**Keep the cut exactly where it is; move only where the read begins, and measure the landing
rather than predict it.**

- The in-cut stays a DTS-midpoint `-segment_times` split (ADR-0008). The seek never places a cut.
- Before the run, `BoundaryReencodeEngine.copyHeadSeek` asks ffmpeg where a seek lands, down the
  same code path the real cut will take: `-ss <anchor> -copyts -c copy -frames:v 1` into a NUT
  file, whose first packet's pts is the answer. `-copyts` is what makes the answer meaningful —
  the packet keeps its *source* timestamp — and NUT keeps it at full precision where Matroska
  would round to a millisecond.
- Every time in the command then rebases onto that landing: the split times by subtraction, and
  `-t`, being a duration rather than an instant, by the same amount
  (`ExportEngine.cutArguments`). The real run deliberately omits `-copyts`: it zeroes ffmpeg's
  `out_time`, which the progress bar reads, and it is not needed — whatever constant offset
  ffmpeg applies to the output timeline cancels, because both the split and the origin move with
  it.
- The anchor is **two** keyframes before the in-cut (`ExportEngine.copyHeadSeekTarget`), so a
  landing that undershoots by one still leaves segment `000` some packets. That matters beyond
  tidiness: with no packets the muxer never writes segment `000`, and `wantedSegmentIndex`'s
  `001` would name a file that does not exist.
- Anything unproven falls back to the read-from-zero recipe, unchanged: no in-cut, no earlier
  keyframe, a failed probe, or a landing not strictly before the in-cut.
- The segments a copy run does not keep are deleted the moment it ends
  (`BoundaryReencodeEngine.discardDeadSegments`) rather than at the export's teardown. With a
  seek that is a couple of GOPs; on the fallback path it is the whole head, and holding those to
  the end of the job is what set the peak.

## Evidence

The wanted piece is **packet-identical** — pts, dts, size and flags — to the read-from-zero
recipe on MPEG-2, H.264 and open-GOP HEVC into `.mkv`, `.mp4` and `.ts`, with and without the
Matroska PTS refill (issue #2) and the export-wide MP4 timescale pin (issue #24); with an out-cut
and reading to EOF; and at an in-cut with only one earlier keyframe. On the real captures, at the
in-point regime that motivated this:

| case | head, unseeked | head, seeked | run |
|---|---|---|---|
| open-GOP HEVC 16.8 GB, 5 s clip 133 min in | 7.82 GB | 0.02 GB | 3.3 s → 0.0 s |
| open-GOP HEVC 16.8 GB, 54 s clip 150 min in | 8.63 GB | 0.00 GB | 3.4 s → 0.0 s |
| PAFF H.264 TS 18 GB, 5 s clip 133 min in | 8.25 GB | 0.01 GB | 3.5 s → 0.0 s |

The probe costs 20–40 ms on a 16.8 GB source.

## Consequences

- A copy segment's read is now proportional to **its own span** rather than to its in-point, so
  the cost of a render stops growing with how deep into a combined recording a class sits. The
  `.segmentMux`/`.boundedKeyframe` split (ADR-0021) stands: the repair path still has its
  keyframes by construction and needs no probe.
- The progress bar tracks the shortened read (`segmentMuxExpectedSeconds` takes the seek), so a
  copy no longer parks the bar for minutes at a fraction of a segment.
- One extra ffmpeg process per cut copy segment. It reads a single packet; against a head this
  size the trade is not close.
- The recipe depends on the NUT muxer being present in the bundled ffmpeg (ADR-0002). If it ever
  is not, the probe fails and every copy quietly reverts to the read-from-zero recipe — slower,
  never wrong.
- `CopyHeadSeekIntegrationTests` is the regression net, because the failure is silent by nature:
  it runs the wired executor over synthesised long-GOP sources in all three codecs and all three
  containers and compares packets, not counts. It owns no copyrighted bytes (ADR-0023) — the
  sources come from `testsrc2`.
