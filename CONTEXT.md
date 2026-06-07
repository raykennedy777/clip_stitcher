# vid_conform

A macOS app for frame-accurate video joining via smart rendering: re-encode only the
frames at edit/join boundaries while stream-copying everything untouched. This file fixes
the project's vocabulary so code, issues, and docs all use the same words.

## Language

### Rendering

**Smart render**:
Producing output by stream-copying every part of a clip that can be copied and re-encoding
only the minimum — the partial GOPs at cut boundaries.
_Avoid_: smart cut, lossless cut, smart rendering (use "smart render")

**Stream copy**:
Copying already-encoded video/audio packets into the output without decoding or re-encoding.
_Avoid_: passthrough, remux, copy

**Boundary re-encode**:
Re-encoding only the partial GOP(s) at a clip's in/out points when a cut falls between
keyframes, so the cut is frame-exact while the rest of the clip is stream-copied.
_Avoid_: partial encode, edge encode

**Keyframe-aligned cut**:
An in/out point that lands exactly on a keyframe, allowing a pure stream-copy with no
boundary re-encode.
_Avoid_: I-frame cut, clean cut

**Conform**:
Fully re-encoding a non-matching clip so its properties match the target clip.
_Avoid_: convert, transcode (when specifically meaning re-encode-to-target)

### Domain concepts

**Target clip**:
The clip whose video and audio properties define the project's output spec. Matching clips
are smart-rendered; non-matching clips are conformed to it. Defaults to the first imported
clip; manually reassignable.
_Avoid_: master clip, reference clip, anchor clip

**Match / Matching**:
A clip matches when all of its strict-comparison properties equal the target clip's. Matching
determines smart-render eligibility (match → smart render; mismatch → conform).
_Avoid_: compatible, conforming

**Clip**:
One imported source file plus its selected in/out range and probed properties, occupying one
row in the timeline.
_Avoid_: track, item, asset

**Source / source file**:
The original media file on disk that a clip references.
_Avoid_: input, original

**Project**:
The ordered set of clips, the chosen target clip, and the output settings; persisted as one
`.vidconform` document.
_Avoid_: session, job, timeline

**Frame index**:
The per-clip map of frame number → timestamp + keyframe flag, built on import. The basis of
frame accuracy on variable-frame-rate content.
_Avoid_: frame table, seek table

### Editing & UI

**Timeline**:
The vertical, chronological list of clips shown in the Source view.
_Avoid_: track, playlist, queue

**Cut-editor**:
The separate per-clip window (opened by double-click/Enter on a clip) for scrubbing and
setting that clip's in/out points.
_Avoid_: preview window, trim window

**In point / Out point**:
The first / last source frame of a clip's selected range, set with the `[` / `]` controls or keys.
_Avoid_: start mark/end mark, trim handles

**Selection range**:
The span of frames from in point to out point that will be included in output.
_Avoid_: trim, segment, region

**Output preview**:
The view that plays back the whole assembled timeline as it would be exported.
_Avoid_: render preview

**Output mode**:
Whether clips are joined into a single file ("Connect into one") or exported as separate
files ("Export separately").
_Avoid_: join mode, merge mode
