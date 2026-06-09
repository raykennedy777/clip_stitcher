# Scene-change jumps run a bounded ffmpeg scene-score scan, not an in-process diff

The cut-editor's ↓/↑ (next/previous scene change) spawns one short-lived ffmpeg process per
press: a hardware-decoded scan of a few seconds around the playhead using the `select`
filter's built-in scene score (`select='gt(scene,T)',metadata=print:file=-`), parsed from
stdout and mapped back to frame numbers via the clip's frame index. The alternative —
decoding through the existing `FrameStreamDecoder` and diffing frames in Swift — was
rejected: the decoder yields display-ready images (no cheap pixel-diff access), playback
owns it while running, and the subprocess recipe already beats the speed bar.

## The recipe (de-risked in the shell on all three formats, 2026-06)

```
ffmpeg -v error -nostdin -hwaccel videotoolbox -copyts -ss <seek> -t <duration> -i <clip> \
  -an -sn -vf "[yadif=0,]select='gt(scene,0.3)',metadata=print:file=-" -f null -
```

- **Wall-clock for a 7s decode (2s guard + 5s window):** HEVC 1080p50 ≈ 0.57s (the worst
  case; VideoToolbox halves it from ≈1s software), SD H.264 ≈ 0.34s, SD MPEG-2 ≈ 0.11s —
  even seeking 50 minutes into the 1.9 GB TS file. All under the ~1s "feels responsive"
  bar, so no downscaled-scan complexity (decode dominates; scaling after decode saves
  nothing).
- **Interlaced sources are deinterlaced (`yadif=0`) before scoring.** A cut on interlaced
  footage lands between fields, smearing the difference across two frames — the same cut
  scored 0.31 raw vs 0.45 deinterlaced on the MPEG-2 clip. Decided per clip by the probed
  field order (`ConformEngine.isInterlaced`), like the preview pipeline.
- **Threshold 0.3.** Ground-truthed by extracting frame strips around every candidate in
  sample windows: real camera cuts scored 0.45–0.77 (deinterlaced), while fast handheld
  motion and photographer flashes — this footage's false positives — peaked at 0.29. One
  soft cut scored 0.23; missing those (the jump then lands at the 5-second cap) is the
  right trade against constantly stopping at non-cuts, which would make the feature feel
  broken.
- **5-second window, land at the cap when nothing is found** (spec), so the key always
  moves the playhead. Backward (↑) scans the previous 5 seconds forward and takes the
  *last* scene change before the playhead.

## Timestamp mapping (the subtle part)

`-copyts` keeps every reported `pts_time` an **absolute** stream timestamp, mapped to a
frame by nearest-PTS binary search over the frame index. The first shipped version
instead reconstructed absolute times from the seek request (`seek + start_time +
pts_time`, relying on ffmpeg's `-ss` re-zeroing) — and landed one frame late on the
H.264 clip: ffmpeg re-zeroes against the **container** start time, which on a file whose
audio leads its video (container 0.0, video stream 0.04) differs from the frame index's
video-stream times by exactly one frame. `-copyts` removes that whole class of offset
bug; `-t` still bounds the decode under it (verified on all three formats). The `frame:`
counters in `metadata=print` output are useless here — they renumber the frames that
*survive* `select`.

The scan seeks a **2-second guard** before the window so (a) the first window frame has a
predecessor to diff against — scene score needs a pair, (b) the TS demuxer's imprecise
byte seek and HEVC open-GOP leading-frame garbage fall inside the guard, not the window.
Guard/slop detections outside the window are dropped by the pure landing rules
(`SceneScan.forwardLanding`/`backwardLanding`, unit-tested).

## Consequences

- One ffmpeg process per key press, bounded by `-t` — torn down via `ProcessRunner`'s
  cancellation kill if the editor closes mid-scan. Presses while a scan runs are ignored
  (no pile-up).
- The threshold is a constant (`SceneScan.threshold`); footage with softer cuts than this
  test set may want it user-tunable later.
- Scene scores live only in the scan — nothing is cached. Repeated jumps over the same
  region re-scan (~0.1–0.6s each), which is fine at these speeds.
