# An HEVC in-point copy may start at an open keyframe

A copy may start only at a copy-safe keyframe — a keyframe with no leading pictures
(ADR-0009, #16). On an open-GOP x265 source every routine keyframe is a CRA with leading
pictures, and only an IDR is copy-safe. x265 writes an IDR only at the start of an encode or
at a scene cut. So a cut in-point re-encoded all the way to the next IDR, which can be
minutes away.

Measured case (2026-11-11): an x265 Main 10 master, 1080p50, a CRA every 250 frames. The
in-point 205508 planned `reEncode 205508 236798 625.8 s` — 31,290 frames, where the next
keyframe (a CRA) was 240 frames away.

The out-point side already has the mirror rule (#16): a copy may end at any keyframe,
because the segment-muxer cut before the keyframe puts its leading pictures into the
discarded segment (`CopyCutSnapper`).

## Decision

**On an HEVC clip, a copy that starts at a cut in-point may start at the first keyframe at
or after the in-point whose leading-picture count is known — the "in-point splice". The
re-encode in front of it ends at that keyframe.** The copy run does three things to the
keyframe `k`:

1. **Drops `k`'s leading pictures.** They present before `k`, so they are inside the
   re-encode `[in, k)`. A `noise=drop=…` bitstream filter in the copy run drops every packet
   that decodes at or after `k` and presents before it. The filter runs **first** in the
   `-bsf:v` chain (before `hevc_mp4toannexb`), so it judges the source's own packets before
   parameter sets are prepended. Its timestamp limits sit a quarter-frame before `k` on
   ffmpeg's shifted timeline (`source − containerStart − askedSeek`), **not** relative to the
   landing probe's `startpts`: on Matroska ADR-0027's landing probe can report one frame later
   than the run actually starts, which a segment cut absorbs but a one-frame drop window does
   not. Earlier packets pass through into segment `000` so `ExportEngine.wantedSegmentIndex`
   stays unchanged.
2. **Moves `k`'s DTS into the hole.** The dropped packets leave a hole in the decode order
   after `k`. A `setts` filter moves `k`'s DTS onto the last dropped picture's DTS. Without
   this, `k` decodes `count` frames earlier than the join's reorder depth needs. In MP4 its
   DTS then collides with the re-encode's last DTS, the muxer bumps it by one tick, and two
   frame durations come out wrong (measured: 1 tick, and 2 frames).
3. **Rewrites the CRA to BLA_N_LP** (`OpenGopSplice.rewriteFirstIrapToBLA`), a 1-byte patch
   of the NAL header in the finished copy piece (`(byte & 0x81) | (18 << 1)`, preserving the
   forbidden bit and high bit of `nuh_layer_id`). `ffprobe` gives the first video packet's
   `pos` and `size`; container framing determines the byte offsets:
   - **MP4:** `pos` is the sample's first byte (4-byte length-prefixed NALs).
   - **Matroska:** `pos` is the SimpleBlock track-number vint (1–8 bytes) + 2-byte timecode +
     1 flags byte, followed by 4-byte length-prefixed NALs.
   - **MPEG-TS:** `pos` is the TS packet starting the PES; the Annex B byte stream can cross
     188-byte TS packets, so each payload byte is mapped back to its file offset after
     stripping the PES header (`9 + payload[8]` bytes).

The plan reports the splice: the re-encode's reason names the keyframe and the dropped
count, and the copy's stage line ends `N leading pictures dropped`.

### Why BLA, not an end-of-sequence NAL

After a foreign re-encoded piece, a CRA is not the first picture of the bitstream. A
decoder that follows the standard then keeps NoRaslOutputFlag at 0: it derives the CRA's
POC from the re-encoded piece's pictures and expects RASL pictures. HEVC has two standard
markers that make the decoder treat the CRA as a new start:

- **BLA** (chosen). It is the IRAP type HEVC defines for a splice point. POC MSB is 0, and
  no leading picture is expected. N_LP is exact, because step 1 removed every leading
  picture. The type is 6 bits of the first NAL header byte, so the rewrite changes no size.
- **End-of-sequence NAL before the CRA** (rejected). It must be inserted, which changes
  sizes, and ffmpeg has no tool for it: no bitstream filter inserts it, and libx265 with
  `eos=1` fails through ffmpeg ("Unknown picture type encountered").

ffmpeg's own decoder decodes the plain CRA correctly too (measured at in-points 10, 50
and 110 frames before the CRA), also when the source was encoded with the same x265
settings as the re-encode (its SPS still differed in the VUI timing). Why it passes was not
measured; a likely cause is that ffmpeg starts a new sequence when the active SPS changes.
That would be ffmpeg behaviour, not the standard, and an identical SPS would remove it. So
the BLA rewrite is kept. No decoder outside ffmpeg was tested: VideoToolbox through ffmpeg
uses ffmpeg's own POC and output logic.

### Proof (shell and `OpenGopInPointIntegrationTests`)

Source: `testsrc2` 320×240 at 50 fps, x265 Main 10, default open GOP, `keyint=250`,
`scenecut=0` — one IDR, then a CRA every 250 frames with 1 or 2 leading pictures. A
two-clip join ([0, 299] and [630, end]), from `.mkv`, `.ts` (start time 1.44 s) and `.mp4`
sources into `.mkv`, `.mp4` and `.ts`:

- the output has exactly 1170 frames;
- across ±300 frames of the seam, every output frame is nearer to its own source frame than
  to any frame within 8 of it;
- the decode is silent (`decodeCheck` with `requireSilentDecode`);
- every copied frame decodes bit-identical to the source frame (`framemd5`);
- in decode order, the DTS advance one frame at a time across ±10 packets of the seam, and
  every packet duration is one frame. With the DTS move turned off, this check fails in
  `.mp4` and `.ts` (MKV stores no DTS);
- the same output checked against frames one off fails the frame match, so the check can
  see a displaced frame;
- the output carries one BLA_N_LP picture.

In-points 260, 499, 500 (on the CRA: a pure copy), 749, 1001 and 1240 gave the same result.
The control turns the splice off (`produceVideoPiece(inPointSplice: false)`: no drop, no
DTS move, no BLA rewrite): the engine's
gate refuses the piece (871 frames for 870), and the test's own checks report the packet
count and the decode errors. The decoder discards the orphan, so no frame is misplaced: the
packet count and the silent decode are the checks that see it. In MKV the orphaned packet has no timestamp
and the concat fails before any check.

A replica of the measured GOP shape (64×64, IDRs at 0, 205498 and 236798) plans
`reEncode [205508, 205748)`, 240 frames, and renders silent with 31992 frames.

## Scope and fallback

- **HEVC only** (`ExportPlanner.allowsOpenInPoint`). H.264 has no BLA type. The same drop on
  an x264 open-GOP source decodes with `mmco: unref short failure` and missing-reference
  errors. MPEG-2 was not tried (its GOP header has a `broken_link` flag that may be the
  equivalent). Both stay on the copy-safe rule (issue #122).
- **Not** on a source with damage zones (its copies skip the parameter-set repeat, and its
  decode is not held to silence), not on the field-coded copy-cut route, not in Clip Doctor
  (`.repair` plans and the bounded copy), and not on a damaged plan's head gap.
- A keyframe whose leading-picture count is `nil` is no copy start.
- **Fallback.** Each spliced item carries `fallbackSegments`, its plan under the copy-safe
  rule. When the rewrite, a cut, the concat or the verify gate refuses the spliced clip, the
  export logs `in-point splice refused` and renders that clip again with the fallback. The
  cost of a failed splice is time, never a broken seam. This path was seen to work in the
  shell (a first version with wrong drop limits fell back in all three containers), but no
  test covers it.
- A clip whose first counted keyframe at or after the in-point is copy-safe plans exactly as
  before.

## Consequences

- An in-point on an open-GOP HEVC source re-encodes less than one GOP.
- `copySafeKeyframes.afterIn` in the plan query keeps its meaning (a keyframe a copy may
  start on with no splice). A mark moved onto any keyframe after it is now also a pure copy
  on HEVC.
- The copied keyframe packet is no longer byte-identical to the source's: its NAL type and
  its DTS change. Its decoded picture is identical.
