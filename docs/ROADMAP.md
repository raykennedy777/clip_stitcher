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
   partial-GOP re-encode (Swift + ffmpeg; smartcut as reference). CLI-only, copying only between
   leading-picture-free keyframes. See ADR-0004 and ADR-0009.
5. **Engine Milestone 3 — conform.** ✅ Full re-encode of non-matching clips to the target spec
   (display-aspect-aware scale/letterbox, scan-type conversion, color/bit-depth, audio
   resample/remix), self-verified against the target before shipping. See ADR-0011.
6. **Output preview.** ✅ Sidebar "Preview" scrubs and best-effort-plays the whole assembled
   timeline as the export will produce it: source-stitched, spatially conform-accurate
   (letterbox/deinterlace via the decode pipeline), playhead in output frames at the target
   clip's rate. No audio in v1. See ADR-0012.
7. **Source view polish.** ✅ Duplicate clip — a new clip row referencing the same source file
   with the same in/out points. Right-click context menu on a clip row: Open in Cut-Editor,
   Duplicate, Delete.
8. **Cut-editor fast navigation.** ✅ Speed is the point of all of these (see ADR-0013 for
   the scene-scan recipe):
   - **Shift+←/→ — previous/next keyframe.** The frame index already knows every keyframe,
     and a keyframe decode is the decoder's cheapest seek, so this must feel instant.
   - **↓ — next scene change**: scan forward comparing successive frames against a
     difference threshold; stop at the first scene change, or give up (and land) at a
     maximum of 5 seconds. **↑ — previous scene change**, same rule over the previous
     5 seconds. De-risk the scan rate in the shell first (ffmpeg scene-change detection) —
     a too-slow scan kills the feature.
9. **Multi-track audio.** ✅ Sources can carry several audio tracks; today the engine uses one.
   - **Output track count = the input with the most** (inputs with 1, 3 and 4 tracks → the
     output has 4), with **silence filling** a track wherever a source has no corresponding
     one.
   - **Per-clip track selection in the cut-editor**: a dropdown naming each track from
     container metadata, always including language metadata when present, falling back to
     "Track 1", "Track 2"… when the container has no names.
   - **Audio stream settings** (reachable from both Source and the cut-editor): add/remove a
     clip's audio tracks and pick each track's source — another stream of the clip's own
     file, or an external audio file. (Reference shape: per-track file name + stream picker
     with Browse / Use Same Source as Video / Delete Audio Source, plus an Add Audio slot.)
   - **Open question:** what to do when an external audio source's length differs from the
     clip's video.
   Touches the audio rebuild (ADR-0010) and MatchEvaluator's audio dimensions — needs its
   own ADR and a shell de-risk of the silence-fill/multi-track mux on all three formats.

### Deferred

- **Engine Milestone 2b — minimal-re-encode open-GOP smart render (libav).** Re-encode only the
  orphaned leading pictures at open-GOP seams (smartcut-style), so MPEG-2/HEVC between-keyframe
  cuts re-encode ~1 GOP per edge instead of the larger CLI-only span. Requires in-process libav
  (reversing ADR-0002) plus NAL parsing + decoder priming. Justified only if the M2 CLI-only
  re-encode cost proves painful in practice. See ADR-0009 for the decision and the baseline
  measurements; M2's design keeps this path open.

## Output options (Output view)

- **Output mode:** Connect into one / Export separately.
- **Output type:** Video + Audio / Video only / Audio only.
- **Container:** TS / MKV / MP4.

## Standing risks — test early

- ~~**Interlaced MPEG-2.**~~ *Retired:* the MPEG-2 re-encode preserves field order
  (`-flags +ildct+ilme` + a `setparams=field_mode=tff` scan filter), verified in the shell
  (ADR-0009). The real open-GOP risk is the leading-picture seam, which is
  codec-orthogonal — handled by copying only between
  leading-picture-free keyframes.
- **Audio alignment at cuts.** Expect to handle A/V offset at join boundaries (audio gap
  correction).
- **Notarization with bundled binaries.** Confirm the signing/notarization flow early so it
  doesn't surprise at ship time (ADR-0002).
- **Frame-index cost** on multi-hour files. Keep the import pass async + cached (ADR-0006).
