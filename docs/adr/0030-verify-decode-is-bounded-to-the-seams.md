# The verify decode is bounded to the seams

Every finished video piece is verified before it ships (ADR-0008, ADR-0009): a frame count,
a full `-xerror` decode, and a timestamp self-check. On the 8-clip round job of the
2026-09-15 review the decode pass took **06:16 of a 15:36 wall clock** — second only to the
boundary re-encodes — and nearly all of it decoded stream-copied frames that no cut had
touched (issue #114).

The decode is the one gate with teeth against a *content* defect. `requireSilentDecode`
is what gives it those teeth (issue #113): a decoder conceals what it cannot parse and
exits 0, so on a clean source the pass must also be **silent**. Every failure mode it
guards is **seam-local**:

- orphaned leading pictures at a re-encode→copy seam (ADR-0009),
- a retained RASL, which shows as a duplicate PTS at the seam,
- a bad copy→MBAFF entry (issue #54),
- the parameter-set mismatch of commit 8bacae6 — which shows on the frames of whichever
  piece does *not* own the join's single container header.

So the decode can be bounded to windows around the seams without changing what it can
refuse.

## Decision

**A finished piece is decoded over one *verify window* per re-encoded segment instead of
from start to EOF, whenever every window's decode entry can be measured onto a copy-safe
keyframe and every window is silent. Otherwise the piece is decoded whole.**

### Verify window

For each `reEncode` segment of the plan, in the piece's own reset timeline (cumulative
`outputCounts` give each segment's frame offset; the piece's own `FrameIndexer.buildIndex`
gives the keyframe pts):

- **start** — the nearest **copy-safe** keyframe at or before the last keyframe strictly
  before the seam, searched only inside the preceding copy segment. None → that copy
  segment's own start, which is copy-safe by construction. No preceding copy segment →
  the piece start.
- **end** — the **second** keyframe of the following copy segment, so one whole copied GOP
  after the seam is decoded. No following copy segment → the piece end.

A copy-only plan gets one window from the piece start to its second keyframe: the cut start
is its only seam. Windows sort and merge; a merged window that covers the piece means
"decode it whole", which is also what a piece shorter than two windows gets.
`BoundaryReencodeEngine.verifyWindows` is pure over those inputs, so every plan shape is
unit-tested without ffmpeg.

**A window never starts at a keyframe that is not copy-safe**, and a window that is not
silent is never accepted — it widens to the whole piece. See "A CRA start is not allowed".

### The decode entry is measured, never predicted

`-ss <pts>` before `-i` does **not** land where it is asked (step 4 below), so each window's
entry is measured with the landing probe of ADR-0027 — one stream-copied packet — and the
window is run only when the landing is a copy-safe keyframe at or before the window start.
The probe writes `framecrc`, not a container: an **mpegts muxer adds its own ~1.4 s base**
to every timestamp it writes, so a probe muxed to `.ts` reports a landing that is 1.4 s late
and a correction loop then walks the entry onto a CRA. The probe must also **copy, never
decode**: a decode-based probe reports the first frame the decoder could *recover*, which on
H.264 is the next IDR — measured 4.78 s past the real landing.

The whole-piece decode stays the authority. A window that exits non-zero, or that is not
silent when silence is required, does not refuse the piece on its own: the piece is decoded
whole and **that** pass is the verdict. The bounded decode is therefore a fast path that can
only ever be as strict as the gate it replaces.

### What keeps the whole-piece decode

- **Field-coded (PAFF) pieces** (`verifyFieldCodedPiece`, issue #54). Its one seam is
  copy→MBAFF at an unknown packet offset and its field-packet cadence defeats the
  frame-offset arithmetic.
- **Conform pieces** (`ConformEngine.verifyConformed`). A conform is one encode with no
  internal seam, so there is no seam to bound to; the de-risk found no measured reason to
  change it (the Fill conform was 01:34 of the 15:36, and all of it is content this gate has
  never had another way to check).
- Any piece whose windows cannot be placed or cannot be entered silently — in practice every
  H.264 and HEVC `.ts` piece (step 4).

## De-risk

All commands run in the shell first, on MPEG-2, H.264 **and** HEVC, in `.mkv` and `.ts`
pieces. The good pieces are **built by the engine itself** (`produceVideoPiece` through a
throwaway `@testable` harness), so the timings and silences are measured on pieces the app
actually ships; the bad pieces are built by hand from the same argument builders with one
thing deliberately wrong.

Sources are synthesised `testsrc2` at 640×360, long-GOP (a keyframe a second) with an IDR
every 10 s — the broadcast shape: a copy may start only at the sparse IDRs, every keyframe
between them is an open-GOP CRA carrying leading pictures (n_leading 1 on H.264, 4 on HEVC,
2 on MPEG-2).

### 1–3. Good pieces: silent, and how much cheaper

| piece | whole-piece decode | bounded decode | windows | verdict |
|---|---|---|---|---|
| h264 `.mkv` | 0.16 s, silent | 0.07 s, silent | 0.00–6.78 s, 74.78–75.58 s | **bounded** |
| hevc `.mkv` | 0.18 s, silent | 0.08 s, silent | 0.00–6.78 s, 74.78–75.58 s | **bounded** |
| mpeg2 `.mkv` | 0.14 s, silent | 0.07 s, silent | 0.00–5.88 s, 64.80–75.60 s | **bounded** |
| mpeg2 `.ts` | 0.14 s, silent | 0.07 s, silent | 0.00–5.88 s, 66.24–77.04 s | **bounded** |
| h264 `.ts` | 0.16 s, silent | not silent | — | **whole** (entry, see step 4) |
| hevc `.ts` | 0.18 s, silent | not silent | — | **whole** (entry, see step 4) |

**Long piece** — 29 880 frames, 597.6 s, plan `reEncode[460] · copy[29 399] · reEncode[22]`:

| container | whole | bounded | share |
|---|---|---|---|
| `.mkv` | 1.04 s | **0.08 s** | **7 %** — windows cover 11.6 s of 597.6 s (1.9 % of the timeline) |
| `.ts` | 1.05 s | falls back to whole | 100 % |

So the "< 10 % of the whole-piece wall time" bar is met on `.mkv`, and the saving does not
shrink as the piece grows: the windows are a constant (one copy-safe keyframe spacing plus
one GOP), not a proportion.

### 2. The three known defects, whole vs bounded

Both decodes must refuse the same pieces, or the bound has cost the gate its teeth. Each bad
piece is assembled from the engine's own argument builders with one thing deliberately wrong,
and the two decodes are run side by side on it (`BoundedVerifyIntegrationTests`).

| defect | format | container | whole-piece decode | bounded decode |
|---|---|---|---|---|
| **(a) orphaned leading pictures** — copy body cut *at* an open-GOP keyframe, keeping its leading pictures | h264 | `.mkv` | *the piece cannot be muxed*: the orphaned packets reach Matroska with no timestamp and the mux fails (exit ≠ 0), so the defect never reaches any gate | — |
| | h264 | `.ts` | **refuses** — rc 183, "reference overflow 67 > 15" | **refuses** |
| | hevc | `.mkv` | *cannot be muxed* (as above) | — |
| | hevc | `.ts` | **refuses** — "Could not find ref with POC 39" | **refuses** |
| | mpeg2 | `.ts` | **refuses** | **refuses** |
| **(b) parameter-set mismatch** — copy-first join, re-encoded tail without `dump_extra` | hevc | `.mkv` | **refuses** — "Invalid number of merging MVP candidates: 246" | **refuses** |
| | h264 | `.mkv` | **silent — the fixture does not express it.** The tail re-encode's parameter sets differ from the copied body's only in rate control, which an H.264 slice header survives. On the real Main 10 capture of issue #113 the same shape gave 165 error lines | silent (parity) |
| | mpeg2 | either | **not applicable** — MPEG-2 repeats its sequence header per GOP in the elementary stream, so it has no header to mismatch | silent (parity) |
| **(c) duplicate PTS at a seam** — shallow-reorder copy body, B-pyramid re-encode | h264, hevc | `.mkv` | **silent — no duplicate PTS produced.** A synthetic join did not reproduce the collapse ADR-0026 measured on real 1080p50 HEVC | silent (parity) |
| | mpeg2 | either | **not applicable** — MPEG-2's B-frames never reference other B-frames, so there is no pyramid to switch on (`EncoderSelection.reorderDepthParams`) | silent (parity) |

So the decode parity holds in **every** cell, and the defect is expressed in five of them: (a) on
all three formats and (b) on HEVC. Where a decode cannot see a defect the gate that does is
named — the mux itself for (a) in Matroska, and `ExportEngine.timestampDefect`, which stays
whole-piece, for the timestamp collapse of (c).

Defects (b) and (c) only arise in a **copy-first** join. Behind a re-encoded *first* piece the
container header is that re-encode's own, and a second re-encode with the same settings decodes
against it unharmed — the first shape tried was silent on both decodes and proved nothing.

**The parity is verified by mutation**, not only asserted: making the bounded pass report a
complaining window as clean fails four of the five expressive cells. Two things had to be true
for that to bite. The comparison runs `decodeCheck` twice on one piece rather than the whole
verify twice — an orphan piece also fails the frame count, which would refuse it before the
decode ran — and the first attempt at these fixtures, built by a python harness, had to be
discarded: its frame index dropped the first Matroska packet (whose dts is `N/A`), so every
`duration` directive came out one frame short and *every* copy-first join carried one duplicate
PTS, whatever the defect. That artifact, not the defect, was what the python runs measured as a
refusal for (b) and (c).

### 4. `-ss` does not land where it is asked

Measured with the copy landing probe on every good piece, asking for a copy-safe keyframe's
own pts (start_time-relative):

| piece | ask | lands | corrected ask | lands |
|---|---|---|---|---|
| h264 `.mkv` | 44.76 | 43.78 (one keyframe early) | 45.76 | **44.78** ✓ |
| hevc `.mkv` | 44.76 | 43.78 | 45.76 | **44.78** ✓ |
| mpeg2 `.mkv` | 4.80 | 4.32 | 5.28 | **4.80** ✓ |
| h264 `.ts` | 34.78 | **36.20** ✓ | — | — |
| hevc `.ts` | 34.78 | **36.20** ✓ | — | — |
| mpeg2 `.ts` | 4.32 | **5.76** ✓ | — | — |

Matroska lands one keyframe early because ffmpeg subtracts a `dts_heuristic` (≈ 0.13 s, from
`3·AV_TIME_BASE/23`) from a seek target on a reordered stream whose demuxer does not seek to
PTS — bisected at 14.9099 against a keyframe at 14.7800, a 0.1299 gap. It is a
version-dependent constant, so it is **corrected by measurement**, never coded as a number:
one probe, one correction of `(target − landing)`, one confirming probe.

`.ts` lands on the asked keyframe first time **for the copy path**, but the *decode* path does
not: the mpegts demuxer seeks by byte position and hands the decoder every packet from there,
so an H.264 or HEVC decode entered mid-file always prints parser complaints. Measured on
`good_h264.ts` at every copy-safe keyframe, with the ask offset from 0.00 to 0.50 s:
**never silent**. HEVC is silent only in a ≈ 0.1 s ask window and noisy either side of it —
too narrow to rely on. MPEG-2 `.ts` is silent. This is not a container rule in the code: the
gate accepts a window only when its landing measures onto a copy-safe keyframe *and* the
window comes back silent, which produces exactly this outcome and will keep producing the
right one when an ffmpeg version changes the heuristic.

### 5. A CRA start is not allowed

Starting a window at a mid-copy keyframe that carries leading pictures, on a **good** piece:

| piece | result |
|---|---|
| h264 `.mkv` | **rc 183**, "reference overflow 67 > 15", "illegal reordering_of_pic_nums_idc" |
| h264 `.ts` | **rc 183**, same class |
| hevc `.mkv` | silent (HEVC discards RASL after a CRA that begins a decode — `NoRaslOutputFlag`) |
| hevc `.ts` | not silent — "The slice_qp 91 is outside the valid range", "Could not find ref with POC 95" |
| mpeg2 `.mkv` | not silent — non-monotonic DTS to the null muxer |
| mpeg2 `.ts` | silent |

Four of six complain, and H.264 does not merely complain — it decodes nothing until the next
IDR (measured: a decode entered at 19.78 s emitted its first frame at 24.78 s). A CRA start
is therefore **not** an allowed fallback. When a copy body holds no copy-safe keyframe the
rule is "widen to the copy segment's start", which always exists.

The rule is never the other way round: a window is not made to pass by relaxing
`requireSilentDecode`.

## Consequences

- An MKV piece pays two short decodes and one or two one-packet probes instead of one decode
  of the whole piece. On the long piece that is 7 % of the wall time.
- An H.264 or HEVC `.ts` piece pays the two probes and one short decode **before** falling
  back to the whole-piece decode — a few tens of milliseconds added to a pass that was
  already going to run. A follow-up could recover these by extracting each window with
  `-c copy` and decoding the extracted file from its own frame 0, which has no seek entry to
  get wrong; it costs a temp file per window and was left out of this change.
- A clip whose source has **no copy-safe keyframe at all** plans as one re-encode with no
  copy segment, `verifyWindows` returns one whole window, and this change saves nothing on
  it. Measured on the real broadcast MPEG-2 capture: **0 copy-safe keyframes in 15 minutes**.
  That is issue #68's territory, not a defect here.
- The frame-count gate (`FrameIndexer.frameCount`) and the timestamp gate
  (`ExportEngine.timestampDefect`) are ffprobe packet scans, not decodes. They stay
  whole-piece and are unchanged.
- **A pre-existing false-fail was found and left alone:** an MPEG-**PS** (`.mpg`) source's
  copy piece muxed to `.mkv` prints "non monotonically increasing dts to muxer" on a plain
  `-f null -` decode, so `requireSilentDecode` refuses a correct piece. It reproduces on a
  bare `ffmpeg -i src.mpg -c copy -bsf:v setts=… out.mkv` — the join is not involved — and it
  is why this de-risk uses an MPEG-2 `.ts` source. Filed as issue #116; #114 does not touch it.
