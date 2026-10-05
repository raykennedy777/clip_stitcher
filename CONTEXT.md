# clip_stitcher

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

**Re-encode rate control**:
The fixed near-lossless quality every re-encoded *piece* of a stream-copied export is held
to — CRF 18 for H.264/HEVC, and for MPEG-2 (which has no CRF mode) a bitrate target derived
from the source's own measured average. An engine constant, not a user control: a boundary
re-encode or repaired segment is seconds-to-minutes inside an otherwise copied file and owes
the copied content beside it the same quality. Distinct from the project's **conform CRF**,
which is a target-spec choice the user makes for a fully re-encoded clip.
_Avoid_: quality setting, bitrate setting

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

**Discarded segment**:
A piece the segment muxer writes because a copy run's split points imply it, and which no
concat list ever names — the source before the in-cut, and whatever the read margin catches
past the out-cut. Real files, on disk, for the length of the run; they are what made a
render's temp footprint a multiple of its output (#107, #108).
_Avoid_: temp file, leftover (they are neither stray nor leaked — the muxer is asked for them)

**Head seek**:
The input `-ss` that starts a copy run at a keyframe shortly before its in-cut instead of at
frame 0, so the discarded head is a couple of GOPs rather than the whole source before the
clip. It never places a cut — the in-cut stays a DTS-midpoint split — so the piece is
identical to the unseeked read (#108, ADR-0027).
_Avoid_: trim, in-point seek (it is a *read* bound, not an edit)

**Landing probe**:
One video packet stream-copied after a seek to *measure* where ffmpeg actually landed, which
the frame index cannot predict — Matroska's cues don't index every keyframe the packet flags
call one. The segment muxer measures `-segment_times` from its first packet, so the landing
is the origin every cut time in a seeked copy run is expressed against (#108, ADR-0027).
_Avoid_: seek point, anchor (the anchor is what was *asked for*; the landing is what happened)

**Timescale probe**:
One source video packet stream-copied into a throwaway MP4 to *measure* the track
timescale the clip's real copy pieces will inherit from the mp4 muxer. Re-encoded pieces
in the same MP4 plan are pinned to that value (`-video_track_timescale`) so the concat
demuxer reads every piece in one timebase (#18, ADR-0009). MP4-only — MKV and TS impose
one timebase per container.
_Avoid_: timebase probe (a stream has a timebase; an MP4 *track* has a timescale)

**Verify window**:
A keyframe-anchored span of a *finished piece* that the verify decode is bounded to, one
per re-encoded segment: from a copy-safe keyframe in the copy before the seam, through the
re-encode, to the second keyframe of the copy after it. Every defect the decode can catch
is seam-local, so the copied middle need not be decoded at all — it was 06:16 of a 15:36
render. A window never *starts* at an open-GOP keyframe (the orphaned leading pictures
print the same flood as the defect the gate exists to refuse), its decode entry is
measured, not predicted (see Landing probe), and a window that cannot be entered or that
is not silent falls back to decoding the whole piece, which stays the verdict (#114,
ADR-0030).
_Avoid_: decode window, seam window, partial verify (it verifies the whole piece — by
decoding part of it)

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

**Channel mix**:
A per-clip, per-audio-track choice of how a source's channels are mixed into its output
track: Original (pass through), Stereo (fold a surround source down to two-speaker
stereo; no-op otherwise), Left only / Right only (one side of that stereo fold-down,
heard alone), or Mono (everything folded to one signal). A channel mix never changes the
output track's channel layout — only what is mixed into it. Options that would be no-ops
for a given source are disabled, and the mix resets to Original whenever the track's
source changes.
_Avoid_: channel settings, downmix option, channel layout (that's the track's shape,
which a channel mix never touches)

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
`.clipstitcher` document.
_Avoid_: session, job, timeline

**Stitch Job**:
The headless CLI's input document (docs/stitch-job.md, issue #105): one versioned JSON
describing a stitch — the ordered clips by plain file path with in/out frames and audio
stream selections, exactly one target, and output settings. A Project as a script would
write one; consumed by the `clipstitch` tool target (ADR-0025), never persisted by the app.
_Avoid_: job file, batch file, manifest

**Plan query**:
`clipstitch --plan <job.json>` and the JSON document it prints (docs/stitch-job.md, issue
#115): every decision a Stitch Job has already made before its first encoder starts — each
clip's treatment, its segment plan with per-segment reasons, its copy boundaries, its copied
share and its frame count, plus the output audio and the run's warnings. It costs the
import-time scans every run pays anyway and writes no media, so a caller can read what a job
would do instead of rendering to find out. The CLI's one deliberate use of stdout.
_Avoid_: dry run, preview, --dry-run

**Source identity**:
What a source file *is* for a cache key (`SourceIdentity`): its real path, size, mtime to
the nanosecond, inode, and a SHA-256 of its first and last 64 KiB. A source replaced or
rewritten in place gets a new identity, so every cache keyed on it misses. It cannot see a
change confined to the middle of a file that also keeps the size and the mtime.
_Avoid_: file hash, fingerprint (a fingerprint here is a tool build's `-version` hash)

**Index cache**:
`clipstitch --index-cache <dir>` (ADR-0031): each source's probe result, Frame index,
field-coded verdict and Damage zones, stored after a scan and read back by a later run on
the same Source identity, ff-tool builds and clipstitch build. Opt-in. A hit gives exactly
the stored values, so a plan from it equals a plan from a fresh scan.
_Avoid_: scan cache, probe cache

**Piece cache**:
`clipstitch --piece-cache <dir>` (ADR-0031): every re-encoded piece — boundary re-encode,
Repaired segment, Conform — stored after its verify gate passes, keyed on the Source
identity, the ffmpeg build, the planned segment and the exact ffmpeg arguments with the
output path replaced. A later render that would run the same encode copies the piece
instead, then verifies it like a fresh one. Copy pieces are not cached. Opt-in.
_Avoid_: render cache, reuse

**Frame index**:
The per-clip map of frame number → timestamp + keyframe flag, built on import. The basis of
frame accuracy on variable-frame-rate content.
_Avoid_: frame table, seek table

**Damage zone**:
One damaged region of a clip's source, found at import (issue #45): a span in source
time where reception dropouts corrupted or destroyed content, recorded on the clip and
shown in the Source view. Detected from demux anomalies (timestamp gaps, timestamp-less
packets, duplicate-DTS bursts — in any stream) confirmed by short seek-anchored decodes;
never by a from-start full decode (corrupt flags avalanche on non-IDR sources). An
audio-only zone is a gap the audio rebuild already fills with silence; a video zone is
what the export repair re-encodes across.
_Avoid_: corruption range, error region, glitch

**Truncated ending**:
The damage zone a stopped-mid-broadcast live capture leaves at end-of-file: a partial
final frame the recording cut off partway through writing. Detected as a video damage
zone spanning that one incomplete frame (never zero-width); repaired by trimming, not
frame-fill (see Repair).
_Avoid_: zero-width zone, EOF zone (internal shorthand, not a user-facing concept)

**Repair / Repaired segment**:
How an export crosses a damage zone (issues #47/#48): the zone's span is dropped by a
time-window select and refilled by repeating the last good frame (the fps fill), so the
source timeline length is preserved exactly. Sole exception: a truncated ending is
repaired by trimming the partial final frame — the output ends on the last complete
frame, up to one frame shorter than the source (nothing follows it to keep in sync). On the smart-render path each video zone
forces a *repaired segment* — a re-encode extending to the surrounding copy-safe
boundaries; on the conform path the select rides the existing chain just before its fps
stage. Every repair is reported on export completion ("Repaired 3 damage zones at …"),
never silent.
_Avoid_: fix, heal, patch, error concealment

**Clip Doctor**:
The repair-only export: takes one damaged source file and produces a full-length repaired
copy in the source's own codec and container — damage zones repaired, nothing trimmed,
nothing conformed — intended as a clean replacement for the damaged original. A **progressive**
source is produced as a smart render of the whole file, so everything outside the repaired
segments is bit-identical to the source; a **field-coded (PAFF)** source takes the
*damage-to-EOF* path instead (it can't be spliced). Audio is rebuilt in the source's own codec
with gap silence-fill in both. Every repair is verified by re-running damage detection on the
output and showing the verdict — clean (zero zones) or a soft warning naming any zone that
survived. Unlike the implicit repair every export performs, Clip Doctor proves the result
rather than only reporting the repair attempt.
_Avoid_: fix tool, restoration, error concealment

**Reorder depth**:
How many frames a decoder must hold back to emit a stream's frames in presentation order
(ffprobe `has_b_frames`): 1 for a simple B-frame cadence, 2 once B-frames reference other
B-frames (a B-pyramid — most modern H.264/HEVC sources, and both encoders' default). An MKV
records **one** reorder depth per file, latched from its first piece, so every piece of a
joined MKV has to agree on it: a deeper piece after a shallower one is read with duplicate
timestamps and frames landing early. Every piece the app *encodes* is therefore produced at
the depth the join's stream-**copied** pieces carry (they can't be changed — that's what
lossless means); where the first clip's own copies are the shallow ones, the export says so
rather than shipping it (issue #106, ADR-0026). TS and MP4 record depth per frame and are
unaffected.
_Avoid_: B-pyramid depth (that's one cause, not the property), DTS delay, has_b_frames in
user-facing text

**Field-coded (PAFF)**:
A source that stores each displayed frame as two field pictures (top + bottom), ~2 packets per
frame, so the app's packet-based frame index runs at 2× the display rate. An H.264 field-coded
source takes the **copy-cut route** (issue #96, ADR-0024): cutting and joining are supported via
pure stream copy, with every mark snapped to a copy-safe keyframe (see Copy-safe keyframe,
Snapped marks) — frame-accurate cutting remains impossible (ADR-0022), so the trade is a mark
that may land up to ~1 GOP from where it was set, never a re-encode. A field-coded source in any
other codec has no validated recipe and stays warn-only, frame-accurate cutting and joining off
by 2×. Clip Doctor *can* repair a field-coded H.264 source (issue #54), via damage-to-EOF,
independent of the copy-cut route.
_Avoid_: interlaced (ambiguous — MBAFF is also interlaced), PAFF without the plain-language gloss

**Scan direction**:
Which field of an interlaced frame is shown first — top-field-first or bottom-field-first. A
re-encoded piece must carry the source's direction, or the fields play in the wrong order,
which shows as judder on motion. The engine sets it with a `setparams=field_mode=tff|bff` filter
placed last in the filter chain; `-flags +ildct+ilme` on the encoder is a separate thing, and
only says the piece is interlaced. ffmpeg 9 removed the old `-top` encoder flag and its
`-field_order` output option does nothing, so the filter is the only way (issue #117,
ADR-0009). The conform **sets** a direction the target asks for; every other re-encode
**keeps** the source's, measured with `idet` when the probed value is indefinite. Every scan
comparison is on the direction (`MatchEvaluator.scanDirection`): ffprobe's `tt` and `tb` are one
top-first stream probed in two containers, because ffmpeg 9 tags every interlaced encode `tb`
and only Matroska stores the tag (issue #119, ADR-0011). The conform gate reads the direction
off the coded frames (`MediaProbe.codedFieldOrder`), since the stream tag carries none for
H.264 outside MKV. MPEG-2 and H.264 re-encodes code interlaced; an HEVC clip is assumed never
interlaced.
_Avoid_: scan order, field order for the flag itself (that is ffprobe's `field_order` value), `-top`,
comparing `field_order` strings

**Copy-cut route**:
The field-coded (H.264) cut/join path (issue #96, ADR-0024): every in point, out point, and
split point snaps to a copy-safe boundary so the resulting export plan is pure stream copy with
no re-encoded segment — re-encoding a field-coded boundary hits the same resume-seam wall ADR-0022
proved fatal for repair. `ExportPlanner` refuses a plan on this route that contains a re-encode
segment as a programming-error backstop. Damage inside the kept range copies through unrepaired;
Clip Doctor first is the workflow for a damaged field-coded source.
_Avoid_: PAFF cutting, field-coded export mode

**Copy-safe keyframe**:
A keyframe with zero leading pictures — the only kind an in point or split point may snap to on
the copy-cut route, since a copy may only *start* where no leading picture would be orphaned at
the seam. An out point may snap to any keyframe (copy-safe or not), landing just before its
leading pictures so they fall in the discarded range (see Leading pictures).
_Avoid_: clean keyframe (that's the closed-GOP cut-point concept from ADR-0008), safe cut point

**Snapped marks**:
An in/out/split point moved by `CopyCutSnapper` from the requested frame to the nearest valid
copy-safe boundary on a field-coded copy-cut clip; ties keep the requested frame inside the kept
range. The playhead follows the snap so the move is never silent. Re-applied whenever a fresh
frame index confirms a clip is field-coded (import, relink, reopen) so stale marks set before
that was known never reach export unsnapped.
_Avoid_: adjusted marks, corrected points

**Damage-to-EOF**:
How Clip Doctor repairs a field-coded source: copy the clean head byte-for-byte up to the
keyframe before the first damage, then re-encode everything from there to the file end as MBAFF
H.264 in one continuous segment (every damage zone dropped + frame-filled). A no-IDR PAFF stream
has no clean resume seam, so a localized splice is impossible (ADR-0022) — this keeps exactly
one copy→re-encode transition (the entry). High-quality (CRF 18) but not bit-for-bit identical
for the re-encoded portion, so it is slower than a smart render and the sheet warns up front and
requires an explicit opt-in.
_Avoid_: full re-encode (only true when the damage is early), transcode

**Audio extent**:
How much audio a written output actually holds, measured from its first timed packet to the end
of its last one's own frame — per audio track, never for the file as a whole. Deliberately not
the container's declared duration (which read 2.03 s of a file holding 8 s of samples on the
issue-#111 render), not an absolute timestamp (the mpegts muxer starts its timeline at its own
clock base), and not a sample count (which was already right on that broken render).
_Avoid_: audio duration, audio length

**Output audio gate**:
The post-mux check that the audio a finished file carries agrees with the plan, and the refusal
that follows when it doesn't: every track's timestamps must advance, and every track's **audio
extent** must land within a few encoded audio frames of the kept duration its clips add up to
(ADR-0029). A file that fails is discarded rather than left at the destination. It gates the
*written output*, unlike the per-piece verification that runs before the mux (ADR-0008).
_Avoid_: audio verification (too vague — say which gate), sync check (nothing here compares
audio to video)

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
