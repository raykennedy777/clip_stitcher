# Engine development workflow

Standing rules for changing the export engine (anything that spawns ffmpeg/ffprobe) and for
verifying changes in the running app. These are hard-won — each line below cost a debugging
session. Follow them.

## De-risk every ffmpeg command in the shell before wiring it into Swift

The engine's recipes are validated against the real footage in the shell **first**, then
pinned in Swift as pure argument builders with unit tests. Never invent an ffmpeg command
straight into Swift and hope.

- **Test on all three formats — MPEG-2, H.264, AND HEVC — never just one.** They differ on
  interlacing, anamorphic SAR, bit depth, and color tagging; a recipe that works on one
  routinely breaks on another.
- **De-risk in the *actual output container*, not a stand-in.** ffmpeg writes (and ffprobe
  reports) stream metadata differently per container. A recipe proven in `.ts` can still be
  wrong in `.mkv` (Matroska re-adds container-level color/timestamp elements that TS omits).
  If the export target is MKV, de-risk the piece as `.mkv`.
  - *Concrete miss this happened on:* a conform color-strip looked clean in `.ts` but the MKV
    muxer kept `color_range=tv`, so the real export still failed self-verify. The `.ts` test
    hid the bug entirely.
- **Probe the way the app probes.** `MediaProbe` uses `ffprobe -print_format json -show_streams`.
  ffprobe's *default* output and its *selective* `-show_entries` can differ from the full JSON
  dump (e.g. omitting vs. emitting an "unknown" field). Reproduce with the same flags the code
  uses, or the de-risk and the runtime can disagree.
- **De-risk perf on a long source, not just the short fixtures.** A recipe can be *correct* but
  *unbounded*: `select=between(...)` without `-frames:v` keeps decoding from the range's end to
  EOF, emitting nothing. On the 8-second fixtures that tail was invisible; on a 72-minute source
  it pinned the CPU for tens of minutes after a 28 s cut and froze the export at 68 %
  (test_sprint diagnosis). Check the run *stops* when its work is done — wall-time on a long
  file, or an explicit frame/read budget in the args.
- **When a concat misbehaves, probe the *list* directly:** `ffprobe -f concat -safe 0 -i list.txt
  -show_entries packet=pts_time,dts_time`. That shows the demuxer's placement *before* the output
  muxer "repairs" non-monotonic DTS (single-tick bumping that masquerades as a different bug).
  This separated demuxer math from muxer fixups in one step on both #18 (MP4 track-timescale
  mismatch between copied and re-encoded pieces) and the #68 Path-1 de-risk.

## Verifying a change in the running app

The GUI is not agent-drivable (issue #5): verify behaviour at the **engine level / in the
shell**, and hand the actual GUI to the user to eyeball.

When you do build and launch the app to hand it over:

- **Force-kill the old instance before relaunching.** `osascript -e 'quit app "ClipStitcher"'`
  is **blocked by any modal dialog** (e.g. an export-error sheet), so `open` then just
  refocuses the *stale* binary — which reads as a "stale build / my fix didn't work" false
  alarm. Use `pkill -f "ClipStitcher.app/Contents/MacOS/ClipStitcher"` first, then `open`.
- Confirm freshness by comparing the running process start time to the built binary's mtime,
  not by trusting that `open` relaunched.

## Build / test

```sh
export PATH="/opt/homebrew/bin:$PATH"
xcodegen generate   # after adding/removing source files; the .xcodeproj is gitignored — never hand-edit
xcodebuild -project ClipStitcher.xcodeproj -scheme ClipStitcher -destination 'platform=macOS' test \
  2>&1 | grep -E "error:|Test run with|TEST (FAILED|SUCCEEDED)" | grep -iv connection
```

- ⚠️ **xcodebuild hang trap:** ffmpeg-spawning integration tests *pass the suite then hang at
  0% CPU instead of exiting*. Run `xcodebuild` in the background to a log file and kill it once
  `Test Suite '…' passed/failed` appears. The unit-only suite exits cleanly.

## More hard-won traps (from agent memory, 2026-08-01)

- **`astats` inside the graph lies about output.** An
  `-af "...,astats" -f null -` tap can report a differently-normalized rematrix
  (FC at 0.293 vs 0.707) because the measurement filter participates in
  swresample's negotiation. When measuring audio filter behavior, encode to a
  file (or pipe raw PCM) with the exact production command shape, then measure
  the artifact in a second ffmpeg run.
- **Keyframe fetch with `-skip_frame nokey`:** one process must fetch ONE
  keyframe (`-frames:v 1`); streaming several emits them out of presentation
  order on open-GOP HEVC and silently drops some. Even single-frame fetches
  MISS ~2/3 of this file's CRAs — read back the emitted pts via showinfo and
  fall back to a plain accurate seek for dropped ones. `KeyframePrefetcher`
  embodies all of this; reuse it.
- **TCC hang masquerades as the xcodebuild hang.** A test host that reads
  media from `~/Desktop` (or any TCC-protected folder) hangs forever at 0% CPU
  on a headless consent prompt. Copy fixtures to `/tmp` before running tests
  against them.
- **Self-signed dev cert vs `xcodebuild test`:** the "VidConform Dev" manual
  signing (kept stable so TCC remembers the grant across rebuilds) breaks
  tests under hardened runtime / debug-dylib split. Fixed in `project.yml`
  (Debug: `ENABLE_HARDENED_RUNTIME=NO`, `ENABLE_DEBUG_DYLIB=NO`) — keep that
  block; if it is ever reverted, pass both flags on the command line. Swift
  Testing selectors match at **suite** level, not function level.
