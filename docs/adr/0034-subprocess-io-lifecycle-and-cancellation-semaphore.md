# Subprocess I/O lifecycle, progress reporting, and cancellation-safe throttling

ClipStitcher drives long-running `ffmpeg` and `ffprobe` subprocesses concurrently across
imports, previews, exports, and repairs. Ad-hoc `Process` plumbing repeatedly caused hangs and
misreported failures: OS pipe-buffer deadlocks (~64 KB) on multi-hour damaged decodes (issue
#59), `SIGTTIN` stalls when launched from detached shells, non-zero exit codes masking user
cancellations (issue #32), and slot leaks when cancelled tasks waited on concurrency throttles.

## Decision

### `ProcessRunner` I/O and cancellation contract

- **`standardInput` is always `/dev/null`.** ffmpeg polls stdin for interactive keys unless
  `-nostdin` is passed; under a background process group (e.g., detached tmux), reading stdin
  raises `SIGTTIN` and freezes the child at 0% CPU.
- **stderr is always drained live into a bounded `StderrTail` (256 KB cap).** Multi-hour
  damaged decodes flood megabytes to stderr even at `-v error`, filling the ~64 KB OS pipe
  buffer and deadlocking ffmpeg if stderr is read only at exit (issue #59). `StderrTail` trims
  at 2× cap (amortising copies) aligned to the next newline or UTF-8 codepoint boundary, and is
  shared with `FrameStreamDecoder` (issue #86). Callers whose stderr is structured data rather
  than a diagnostic tail (e.g., `DamageDetector`'s `-vf showinfo` output) pass `stderrTo:` to
  redirect directly to a temp file.
- **Large stdout uses `stdoutTo:`, `onStdout:`, or both (tee).** Streaming (`onStdout:`) and
  tee (`stdoutTo:` + `onStdout:`) use a single serial reader with an EOF semaphore so chunk
  ordering and completeness hold for line-based packet parsers (issues #81, #84). Streamed
  ffprobe CSV chunks in `FrameIndexer` decode as UTF-8 with an ISO Latin-1 fallback (1:1 byte
  mapping) so a stray non-UTF-8 byte never drops a chunk of frame rows.
- **Cancellation supersedes exit status (issue #32).** `withTaskCancellationHandler` calls
  `process.terminate()`, which yields a non-zero exit status indistinguishable from a tool
  failure. `ProcessRunner.run` checks `try Task.checkCancellation()` after termination so
  cancelled runs always surface as `CancellationError`.

### FFmpeg progress reporting (`ExportProgress`)

- Export commands pass `-progress pipe:1 -nostats` (safe because exports write media to files,
  never stdout; `-nostats` keeps stderr clean for errors).
- Both `out_time_us` and `out_time_ms` emit **microseconds** in ffmpeg (verified across MPEG-2,
  H.264, and HEVC); dividing `out_time_ms` by `1_000_000` is deliberate.
- Values may be `N/A` before frame 1 and are always output-timeline-relative (starting at 0
  regardless of source `start_time`). Export progress maps onto a 70% video / 30% audio split
  with a damped EMA ETA.

### Cancellation-safe FIFO throttling (`AsyncSemaphore`)

- `AsyncSemaphore` coordinates actor-isolated FIFO waiter queues with Swift's off-actor
  `withTaskCancellationHandler` `onCancel` closure using two tracking sets (`live` and
  `cancelledBeforeRegister`) plus remove-before-resume under actor isolation:
  - A cancelled waiter throws `CancellationError` without claiming a slot (preventing slot
    leaks that would wedge imports or probes); only a normal return claims a slot and must be
    paired with `release()`.
  - `cancelledBeforeRegister` catches an `onCancel` hop that wins the race before
    `withCheckedThrowingContinuation` registers, preventing lost cancellations.
  - `live` bounds `cancelledBeforeRegister` so late cancellations after a normal resume cannot
    leak UUIDs; `defer` clears both sets.
  - Removing the waiter before resuming under actor isolation guarantees single-resume against
    a racing `release()`.

## Consequences

- Long/damaged ffmpeg runs no longer deadlock on stderr or hang on stdin in detached sessions.
- User cancellations across export, preview, and Clip Doctor cleanly propagate
  `CancellationError` without tripping tool-failure dialogs or leaking throttle slots.
- Callers expecting >64 KB on stdout must pass `stdoutTo:` or `onStdout:` until in-memory
  stdout capture is also converted to live draining.
