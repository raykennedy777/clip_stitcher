# Cut-editor audio playback: PCM subprocess into AVAudioEngine, audio as the master clock

Cut-editor playback (Space) now plays the monitored audio track (issue #7). The audio path
is a second long-lived ffmpeg subprocess — like the video's `FrameStreamDecoder` — decoding
the monitored source to raw PCM on stdout (ADR-0002: bundled CLI binaries, no in-process
libav), scheduled onto an `AVAudioPlayerNode` by the standalone `AudioStreamPlayer`
component. The player node's sample time is the **master clock**: the play loop derives the
frame on screen from elapsed audio time instead of ADR-0003's open-loop `Task.sleep`
stepping, so decode pacing drift can no longer become lip-sync error — when decode lags,
frames are skipped to hold sync. Scrubbing and frame-stepping stay silent (v1 scope);
playback without a playable audio source falls back to the old sleep pacing.

`AudioStreamPlayer` is deliberately not welded to `CutEditorModel`: the output preview
(#8) adopts the same component for its stitched-timeline audio.

## The recipe (de-risked in the shell on all three formats + the 4-track MKV, 2026-06)

```
ffmpeg -v error -ss <pts − container start_time> -i <file> -map 0:a:<N> -vn \
  -f f32le -ac 2 -ar 48000 -
```

- **Input `-ss` is measured from the container's start_time, not absolute pts** — the
  ADR-0013 trap again. On the 0.24 s-start MPEG-PS clip, `-ss 10.24` lands at absolute
  10.48 (exactly start_time late); `-seek_timestamp 1` does **not** change this. So the
  seek value is `pts[frame] − format.start_time`, with the start_time probed once per
  editor session (`MediaProbe.containerStartTime`). The frame index's `pts[0]` is *not* a
  substitute: it is the **video stream's** start (0.040 on the H.264 clip), while the
  container start there is 0.
- The same value aligns an **external audio file** with no extra probing: its timeline
  starts at the video file's start (ADR-0014), and `-ss` into it is file-start-relative too.
- Landings are **sample-exact** (ffmpeg's default accurate-seek decodes and discards up to
  the target), so A/V offset isn't quantized to audio-frame boundaries.
- Every source is conformed to one engine format — 48 kHz stereo float (`-ac 2 -ar 48000`),
  covering the mono mp2 and ac3 tracks of the 4-track MKV — so the engine graph never
  reconfigures per stream.
- **Measured:** 16–25 ms spawn-to-first-byte on all formats (play and track-switch start
  feel instant); decode 300–470× realtime; a seek past the source's end returns EOF in
  ~10 ms.

## The clock (verified against AVAudioEngine in a shell harness)

`AVAudioPlayerNode.playerTime` starts at zero on `play()` — called only once the first
decoded buffer is scheduled, so clock zero ≈ the seek point — and **keeps advancing after
scheduled buffers run dry** (the node renders silence). That trailing-silence behavior is
load-bearing: an external file shorter than the video, or audio that ends before the out
point, plays out as silence while the picture keeps moving, matching export semantics
(ADR-0014). A stream that yields *no* samples within 0.3 s (e.g. playing from beyond the
audio's end) flips the session to sleep-paced fallback instead of stalling.

Backpressure is the pipe: the reader schedules at most ~1 s of buffers, and a full pipe
holds ffmpeg back. The queue gauge is a lock-guarded **counter polled interruptibly — not
a `DispatchSemaphore`**. The first shipped version used a semaphore signalled by
buffer-consumed callbacks and crashed on a mid-play track switch: `node.stop()` destroys
queued buffer commands **without invoking their completions** (measured in a shell
harness: exactly one completion dropped per stop, deterministically), so the semaphore's
waits go unbalanced — the reader can block forever, and when a destroyed command's block
releases the last semaphore reference, libdispatch traps ("Semaphore object deallocated
while in use"). Never capture a semaphore in `scheduleBuffer` completions. The fixed
pattern survived 50 hostile play/stop cycles in the same harness. There is no in-target
regression-test seam — the bug needs AVAudioEngine's realtime command queue, and
engine-spawning tests can't run under the pure-unit-test constraint — so the shell
harness is the regression test for this class of bug.

Seek-during-play and a mid-play monitor-track switch are both just a restart: kill the
process, spawn at the new position, clock re-zeros at the new base. `teardown()` kills
the audio process under the same no-orphans rule as the video decoder.

## Consequences

- The export's audio seek (`ExportEngine.audioInputArgs`) passes **absolute** pts to
  `-ss` — by this ADR's measurement it starts audio legs 0.24 s late on the MPEG-PS clip.
  Flagged on issue #3 (audio join offset), not fixed here.
- The clock assumes the monitored source's samples sit at their presentation time from
  the seek point on; a source whose audio *starts* later than the seek point would play
  early by the gap. None of the test clips do this; revisit if one appears.
- Audio Settings edits that re-point the monitored slot mid-play don't restart the stream
  (the dropdown does); the next play, seek, or track switch picks them up.
- Play-session end rule (`CutEditorModel.playbackEnd`, from this issue's QA): the out
  point stops a session that started before it; a session starting at or past the out
  point — or re-based there by a mid-play seek — runs to the clip end. Previously Play
  was a dead button from the out point onward.
- **Amended 2026-06-11 (scroll-scrub design session):** user-initiated seeks no longer
  restart playback — *any* seek from *any* input (arrows, scrubber drag, jump popover,
  scene jumps, in/out links, scroll-scrub) now **pauses playback and lands on the new
  frame**, in both the cut-editor and the output preview. Space resumes. The
  restart-on-seek machinery above is retained for what still needs it (mid-play
  monitor-track switches); it just stops being invoked for user seeks. This also
  retires the mid-play-seek branch of the play-session end rule.
