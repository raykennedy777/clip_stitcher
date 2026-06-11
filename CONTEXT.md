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

**Leading pictures**:
Frames that present *before* their keyframe but decode *after* it (HEVC RASL frames; the
B-frames before an open-GOP MPEG-2 I-frame). They make copy boundaries asymmetric: a copy
span may *start* only at a keyframe with none (they would be orphaned at the
re-encode→copy seam), but may *end* at any keyframe — the segment-muxer cut before the
keyframe sends its leading pictures into the discarded segment, so the copy ends exactly
at presentation index `keyframe − count` (#16, ADR-0009).
_Avoid_: open-GOP frames, RASL (except when HEVC-specific)

**Timescale probe**:
One source video packet stream-copied into a throwaway MP4 to *measure* the track
timescale the clip's real copy pieces will inherit from the mp4 muxer. Re-encoded pieces
in the same MP4 plan are pinned to that value (`-video_track_timescale`) so the concat
demuxer reads every piece in one timebase (#18, ADR-0009). MP4-only — MKV and TS impose
one timebase per container.
_Avoid_: timebase probe (a stream has a timebase; an MP4 *track* has a timescale)

**Conform**:
Fully re-encoding a non-matching clip so its properties match the target clip.
_Avoid_: convert, transcode (when specifically meaning re-encode-to-target)

**Assumed input spec**:
The color standard the conform engine assumes for an untagged source before converting it
toward a color-tagged target (≤ 576 lines: BT.601, 625- or 525-line by frame-rate family;
taller: BT.709). Always surfaced as an export warning naming the clip and the standard
(issue #35, ADR-0011).
_Avoid_: default color, guessed color

**Cut-only**:
The separate-mode rendering choice that cuts each clip in its own format with the minimum
encoding: boundary re-encode in the clip's own codec at cut points, stream copy elsewhere,
each audio track rebuilt to its own source's codec/rate/layout. The target clip plays no
role. The alternative rendering choice is conform-to-target (see Conform).
_Avoid_: accurate cut, lossless cut, passthrough, individual output

**Audio rebuild**:
Decoding every clip's audio over its kept range and re-encoding it as continuous,
sample-level output tracks to the target clip's audio codec — done on every export, since
audio is never stream-copied (it would drift from the frame-exact video cut). One rebuild
chain per output audio track, with silence filling where a clip has no corresponding
track (ADR-0014). Distinct from smart render, which copies what it can.
_Avoid_: audio passthrough, audio copy

**Audio track**:
One audio stream position, numbered from 1. A clip's audio tracks are its ordered selected
audio sources (a stream of its own file or an external audio file); the output has as many
audio tracks as the richest clip. "Track" alone stays reserved for audio — a clip is never
a "track" (see Clip).
_Avoid_: audio channel (that's mono/stereo layout), audio stream (use for the raw stream
inside a container)

### Domain concepts

**Target clip**:
The clip whose video and audio properties define the project's output spec. Matching clips
are smart-rendered; non-matching clips are conformed to it. Defaults to the first imported
clip; manually reassignable.
_Avoid_: master clip, reference clip, anchor clip

**Match / Matching**:
A clip matches when all of its strict-comparison **video** properties equal the target
clip's. Matching determines smart-render eligibility (match → smart render; mismatch →
conform). Audio never enters the verdict — every audio leg is conformed inside the
rebuild chain (ADR-0014).
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

**Split point**:
A frame marker placed inside a clip's selection range that divides it; the marked frame is
the first frame of the split range that follows it. A split point outside the selection
range is inert — it has no effect unless the range widens to include it again.
_Avoid_: cut point, split marker, blade point

**Split range**:
One span of a selection range between consecutive split points (or a split point and a
range end). Confirming the cut-editor turns each split range into its own clip.
_Avoid_: segment, section, sub-clip

**Playhead**:
The current frame position in the cut-editor or output preview — the frame shown on
screen, marked by the vertical line on the scrubber.
_Avoid_: cursor, position marker, needle

**Scrub**:
Moving the playhead by a pointing gesture — dragging the scrubber or scrolling
(vertically; toward page-top is backward) over the preview content — as opposed to
stepping by keys or jumping by typed value.
_Avoid_: seek (that's the engine operation any input triggers), skim

**Jump popover**:
The cut-editor control for moving the playhead to a typed timecode or frame number, in
either relative (offset from the playhead) or absolute (from the clip's first frame) mode.
_Avoid_: go-to dialog, seek box

**Output preview**:
The view that plays back the whole assembled timeline as it would be exported.
_Avoid_: render preview

**Output mode**:
Whether clips are joined into a single file ("Connect into one") or exported as separate
files ("Export separately").
_Avoid_: join mode, merge mode

**Join**:
The boundary between two consecutive clips in the assembled output — where one clip's kept
range ends and the next begins. Marked on the output preview's scrubber.
_Avoid_: seam, splice, junction
