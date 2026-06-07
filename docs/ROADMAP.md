# Roadmap

Incremental build order. Each slice should leave the app runnable. See `docs/adr/` for the
reasoning behind these choices and `CONTEXT.md` for vocabulary.

## Build order

1. **Slice 1 — App shell + Source view.** Document-based SwiftUI app with the three-section
   sidebar (Source / Output / Preview). Working Source view: Add file, vertical clip list with
   probed metadata, Move up, Move down, Delete, Clear, Set as target clip (default = first
   imported). Import runs `ffprobe` + the frame/keyframe index pass (with progress). No preview
   or export yet. Establishes the Clip/Project data model, document save/load, and proves the
   bundled-ffmpeg subprocess plumbing via `ffprobe`.
2. **Cut-editor window.** Separate per-clip window (double-click / Enter): FFmpeg-decoded
   source-frame display, scrubbing timeline, frame step ±1, frame/total/timecode/selection
   readout, in/out via `[` / `]` buttons and keys. Best-effort playback, no audio.
3. **Engine Milestone 1 — keyframe-aligned cuts.** Export via pure stream-copy + concat when
   in/out points land on keyframes. Proves the full pipeline end to end with zero re-encode.
4. **Engine Milestone 2 — boundary re-encode.** Frame-exact cuts between keyframes via
   partial-GOP re-encode (Swift + ffmpeg; smartcut as reference). See ADR-0004.
5. **Engine Milestone 3 — conform.** Full re-encode of non-matching clips to the target spec.
6. **Output preview.** Sidebar "Preview" plays back the whole assembled timeline.

## Output options (Output view)

- **Output mode:** Connect into one / Export separately.
- **Output type:** Video + Audio / Video only / Audio only.
- **Container:** TS / MKV / MP4.

## Standing risks — test early

- **Interlaced MPEG-2.** Broadcast TS is usually interlaced; smartcut's handling is
  undocumented. Verify before trusting Milestone 2.
- **Audio alignment at cuts.** TMPGEnc exposes "audio gap correction"; expect to handle A/V
  offset at join boundaries.
- **Notarization with bundled binaries.** Confirm the signing/notarization flow early so it
  doesn't surprise at ship time (ADR-0002).
- **Frame-index cost** on multi-hour files. Keep the import pass async + cached (ADR-0006).
