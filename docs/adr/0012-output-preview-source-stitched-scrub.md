# Output preview is a source-stitched scrub, not a rendered file or AVPlayer

The output preview (sidebar "Preview") shows the assembled timeline by decoding the right
**source** frame for any playhead position and displaying it — stitching the clips' kept
ranges together live — rather than running a real export and playing the result, or handing
the timeline to AVPlayer. AVPlayer is out for ADR-0003's reasons (AVFoundation cannot open
MPEG-2/TS, and the preview must be frame-accurate); a render-and-play preview would mean a
full export (minutes of conform re-encode) before the first frame appears, where a
source-stitched scrub shows it in milliseconds and reuses the cut-editor's streaming
decoder (`FrameStreamDecoder`) unchanged.

## How the stitch works

- The timeline is the clips' kept ranges concatenated in order. The playhead moves in
  **output frames at the target clip's frame rate** — the frames the exported file will
  actually have. An output frame maps to (clip, time within its kept range) and from there
  to that clip's own nearest source frame via its own fps.
- **Conformed clips preview conform-accurately, but only spatially.** A non-matching clip's
  decode pipeline gets the *spatial* steps of its conform filter chain (deinterlace, scale,
  pad/letterbox) so it previews at the shape the output will have. The *temporal* step (the
  `fps` filter) is deliberately **not** inserted: it duplicates/drops frames, which would
  break the decoder's frame-counting seek arithmetic (frame N in the index would no longer
  be frame N out of the pipe). Frame-rate conversion is instead done by the playhead time
  mapping above — mathematically the same drop/duplicate the `fps` filter performs, with
  the decoder's arithmetic intact. Likewise no `interlace`, `format`, or `setparams` tail:
  the preview renders progressive RGB regardless of the output's scan/pixel format.
- The decision of *which* clips get the conform treatment is the same `MatchEvaluator`
  verdict the export uses, so the preview transforms exactly the clips the export would.
- The canvas is the **target clip's display size** (SAR applied, capped — the cut-editor's
  `previewSize` rule), since conform makes every output frame that shape.

## Consequences

- v1 matches the cut-editor's fidelity: scrub + frame-step + best-effort Play, **no
  audio** (ADR-0003). Real-time playback with audio remains the same deferred upgrade.
- The handful of frames the export actually re-encodes (boundary re-encodes at joins, and
  conform's encoder output) preview as their decoded source/filtered equivalents — visually
  near-identical, not the literal output bitstream. An exact "render this join" check is a
  possible later slice, not v1.
- One `FrameStreamDecoder` (an ffmpeg process) per visited clip lives while the Preview
  section is shown; navigating away must tear them all down — the preview is a sidebar
  section, not a window with a close lifecycle like the cut-editor.
