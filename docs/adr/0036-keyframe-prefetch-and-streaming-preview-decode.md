# Streaming preview decoder and one-shot software keyframe prefetch

ADR-0003 established FFmpeg-decoded cut-editor frames and noted a long-lived streaming decoder
as a future optimization. One-process-per-frame extraction was too slow for responsive stepping
and scrubbing, while restarting a live decoder on every `⇧←`/`⇧→` keyframe jump still paid
~0.3 s of GOP warm-up per step (issue #34).

## Decision

### Long-lived streaming decoder (`FrameStreamDecoder`) and single retargeting worker

- **Streaming RGB pipe:** `FrameStreamDecoder` keeps one `ffmpeg` subprocess streaming raw RGB
  frames over stdout (1–2 ms per sequential forward frame), restarting at the nearest keyframe
  only when seeking backward or into a later GOP. Blocking pipe I/O runs on a dedicated serial
  `DispatchQueue` (never the main thread or Swift concurrency pool).
- **Start-time-relative seeking (issue #36):** Every preview seek passes `-ss` relative to
  `containerStart` (`pts - containerStart`, clamped `>= 0`) — never raw absolute PTS, which
  lands a full GOP late on non-zero-start containers like MPEG-PS.
- **Single retargeting decode worker:** Both `CutEditorModel` and `PreviewModel` run one worker
  draining `pendingFrame` toward the latest requested frame, so holding an arrow key or
  scrubbing retargets the worker instead of cancelling in-flight decodes.
- **Trailing-window backfill + bounded FIFO cache:** `FrameStreamDecoder.image(at:)` returns
  the trailing window of frames decoded while advancing through a GOP so `CutEditorModel`
  populates its 48-frame FIFO cache for instant backward stepping. Jumps exceeding `cacheCap`
  (when not served from the keyframe cache) paint an immediate `keyframePreview` frame first
  while leaving the live stream positioned to advance to the exact target; ±1 steps suppress
  this flash.
- **Live stderr drain & safe EOF snapshot (issues #59, #86):** `FrameStreamDecoder` drains
  stderr live via `StderrTail` so decode failures are logged instead of silently falling back
  to `FrameExtractor`. On early stdout EOF, remaining stderr is drained synchronously only when
  `process?.isRunning != true` to avoid blocking the serial queue while ffmpeg is still alive.
- **Single-frame fallback (`FrameExtractor`):** Uses a 3-tier fallback when the streaming
  decoder fails or a full-resolution snapshot is requested: (1) keyframe input-seek +
  `select=eq(n, offset)` (anchoring at frame 0 on headless starts); (2) `-sseof -2 -update 1`
  for the last 1–2 frames (`n >= count - 3`) to survive B-frame/EOF flush drops; (3) slow
  output-seek to the prior/target PTS midpoint (also `containerStart`-relative).

### One-shot software keyframe prefetcher (`KeyframePrefetcher`, issue #34)

- **One process per keyframe, software decode:** Neighboring keyframes around the playhead are
  warmed using short-lived `-skip_frame nokey -frames:v 1` processes (50–80 ms). Streaming
  multiple keyframes from one `nokey` process reorders and silently drops frames on open-GOP
  HEVC, and software decode beats VideoToolbox warm-up on a single intra frame (50 ms vs 80 ms
  measured).
- **Emitted-PTS verification & hardware-decoded fallback:** Open-GOP HEVC `nokey` silently
  skips ~2/3 of mid-stream CRAs and emits the next keyframe. Every fetched frame's actual
  `pts_time` is parsed from `showinfo`, mapped via `pts[frame] + relative`, and accepted only
  if it lands within 40% of the local frame spacing (`nearestFrame`). Missed keyframes fall
  back to a plain accurate GOP decode **with** `-hwaccel videotoolbox` (where hardware beats
  software over a full GOP).
- **Separate 16-entry LRU cache:** Keyframe images live in a dedicated bounded LRU independent
  of the 48-frame FIFO cache so GOP decode windows cannot evict warmed keyframes.
- **Fall-through re-anchoring & playback suspension:** A keyframe cache hit paints immediately
  **and still falls through** to the live `FrameStreamDecoder` so subsequent ±1 steps remain
  anchored and instant. Prefetch runs once per anchor keyframe (nearest neighbors first), paints
  immediately if the user is still waiting on that frame, and suspends during playback.

## Consequences

- Forward stepping, backward stepping within the FIFO window, and `⇧←`/`⇧→` keyframe jumps all
  feel instantaneous without sacrificing ADR-0003's frame-exact open-GOP accuracy.
- Because `KeyframePrefetcher` verifies every emitted PTS, a dropped CRA can never pollute the
  cache under the wrong frame number.
