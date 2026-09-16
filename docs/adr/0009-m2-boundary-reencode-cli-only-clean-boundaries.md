# Milestone 2 boundary re-encode is CLI-only and copies only between leading-picture-free keyframes

The boundary re-encode (engine Milestone 2, ADR-0004) is implemented with the bundled
`ffmpeg`/`ffprobe` CLI binaries only (upholding ADR-0002), with **no in-process libav linkage**.
A frame-exact cut between keyframes is produced by re-encoding from the cut to the nearest
**leading-picture-free keyframe**, stream-copying the keyframe-bounded span between, and
re-encoding from the last leading-picture-free keyframe to the out-point — then concatenating.
The minimal-re-encode, libav-level approach (smartcut-style) is deferred to a **future milestone**.

> **Amended (#16): copy boundaries are now asymmetric — only the *start* needs a
> leading-picture-free keyframe.** A copy span may **end** at *any* keyframe `K`, at
> presentation index `K − n_leading`: the segment-muxer out-cut lands just before `K`'s DTS,
> which sends `K`'s leading pictures into the discarded segment with no bitstream surgery —
> the kept piece is exactly "everything presented before `K` minus its leading pictures"
> (verified in the shell: frame count + bit-identical content + the three verify gates, on
> the real open-GOP HEVC at `n_leading` 1–4 including the full 72-min source, the real
> open-GOP MPEG-2 at 1–2 with its 0.24 s `start_time`, and the closed-GOP H.264 degrade
> case, whose commands come out byte-identical to the pre-#16 model). The tail re-encode
> then starts at `K − n_leading`, covering the leading-picture slots and the rest from
> decoded source — frame-exactness is preserved by construction. Plan-wise,
> `PlannedSegment.outCutKeyframe` carries the cut anchor `K` separately from the copy
> range's upper bound (`K − n_leading`), because the muxer cut time derives from the
> *keyframe's* DTS midpoint, not the range end. The strict rule stays on the start side:
> copying *from* an open keyframe would orphan its leading pictures at the seam — that is
> #68's territory (RASL packet surgery, or Milestone 2b). The measurements below predate
> the amendment: open-GOP **tail** edges now re-encode only the leading-picture slots plus
> the partial out-GOP; head edges keep the clean-point cost until #68.

> **Amended (#18): an MP4 plan mixing copy and re-encode pieces pins one video track
> timescale.** MP4 has a *per-track* timescale: a stream-copied piece inherits one from the
> source via the mp4 muxer, while a re-encoded piece gets the encoder default (1/12800 at
> 25 fps) — and the concat demuxer reads every listed file in the first piece's timebase, so
> the mismatch collapses (or stretches) the second piece's timestamps when the muxer "repairs"
> the resulting DTS. The inherited value is **measured, never derived**: one source video
> packet is stream-copied into a throwaway MP4 (the *timescale probe*) and its `time_base`
> read back — the source's own probed timebase is not the answer (the muxer auto-raises an
> MKV's coarse 1/1000 to 1/16000 on copy, but honors an explicit flag of 1000, so deriving
> from the source would still mismatch). Re-encoded pieces then carry
> `-video_track_timescale <N>`. MP4-only: MKV (1/1000) and TS (1/90000) impose one timebase
> per container and are immune; an unreadable probe omits the flag (pre-#18 behavior, still
> caught by the verify gates). Verified in the shell on all three codecs in MP4 — synthetics,
> the real Jerez H.264 (long-source command shape), and the real open-GOP HEVC window at
> `n_leading = 3`. The same mismatch at **cross-clip** MP4 joins (different-timescale sources;
> conform pieces next to smart-render pieces) is real but unfixed by this — tracked separately.

## Context: why CLI-only forces clean-boundary copying

A stream-copied middle that begins on an **open-GOP** keyframe (HEVC CRA, MPEG-2 open GOP)
carries *leading pictures* — frames that present before the keyframe but decode after it,
referencing the previous GOP. Decoded standalone they drop harmlessly, but concatenated after a
**re-encoded** head their references resolve into the re-encoded frames and they inject duplicate/
corrupt frames at the seam (verified in the shell: a 3-part MPEG-2 cut came out +2 frames,
alignment broken from the seam on). `ffmpeg -c copy` cannot drop the interleaved leading-picture
packets without decoding, so the only CLI-safe copy boundary is a keyframe with **no leading
pictures**. (H.264 closed-GOP has none → every keyframe qualifies and the H.264 recipe is
frame-exact, proven in the shell.)

The reference implementations confirm the fork: **smartcut** (the ADR-0004 reference) solves the
seam by re-encoding *only* the orphaned leading pictures with decoder priming and copying the
rest — but it does this with PyAV/libav packet- and frame-level control, impossible in plain
ffmpeg CLI. **lossless-cut** *is* CLI-only and does **not** solve it (its smart cut glitches
±1–2 frames on open-GOP and is marked experimental).

## Considered options

Measured on the three real test clips (3-minute windows, packet-level detection, general
leading-picture test):

| Clip | Keyframes that are leading-picture-free | Re-encode per cut edge: CLI-only vs libav |
|------|------------------------------------------|--------------------------------------------|
| H.264 | 100% | ~119 vs ~119 frames — no penalty |
| HEVC | 18% | ~950 vs ~120 frames (~4–8×, up to ~57s/edge) |
| MPEG-2 | 4% | ~465 vs ~7 frames (~33–66×, up to ~60s/edge) |

- **CLI-only (chosen):** always frame-exact; optimal on H.264; on open-GOP re-encodes more but
  stays bounded (clean points recur every ~9–28s) — far from a full-file re-encode. Stays within
  ADR-0002/0004. Reuses the existing frame index and clean-cut machinery.
- **libav-level / smartcut-style (deferred):** re-encodes only ~1 GOP per edge on every format,
  but requires linking libav in-process (reversing ADR-0002) plus NAL parsing, decoder priming,
  and frame/packet surgery — "the hardest code in the project" (ADR-0004). Justified only if the
  CLI-only re-encode cost proves painful on real footage; the measurement above is the baseline
  for that future decision.

## Decision details

- **Copy boundaries use the *general* leading-picture test, not M1's MPEG-2 shortcut.** ADR-0008
  marks *every* MPEG-2 I-frame a clean cut point because, for M1's copy→copy concat, a copied
  prior segment retains the frames the leading B's reference. That reasoning **does not hold for
  M2's re-encode→copy seam** (the prior GOP is re-encoded, so those leading B's are orphaned).
  M2 therefore needs the leading-picture-free test applied uniformly across codecs. To avoid
  regressing M1, the two notions are kept distinct (e.g. an M1 "clean cut point" vs an M2
  "copy-safe boundary"); the frame index already carries the per-frame DTS needed for both.
- Detection remains the reliable **packet-level pts/dts + NAL/keyframe** pass the indexer already
  runs (ADR-0006/0008); ffprobe *frame*-level pts/dts is unreliable here (often reports
  pts==dts / presentation order) and must not be used for leading-picture detection.
- Re-encoded segments must match the source stream's codec/profile/pix_fmt/SAR/field-order or the
  concat is rejected / the picture corrupts (e.g. HEVC is 10-bit `yuv420p10le` → libx265 10-bit;
  interlaced MPEG-2 → `mpeg2video -flags +ildct+ilme -top 1` preserves `field_order=tt`, verified).

## Consequences

- On open-GOP-heavy footage (broadcast MPEG-2/HEVC) a between-keyframe cut re-encodes a larger
  span than strictly necessary (bounded, tens of seconds per cut edge), with a corresponding
  localized quality generation-loss over that span. Accepted for now as the price of a correct,
  CLI-only, frame-exact M2.
- **Interlacing is retired as a standing risk** (ROADMAP/ADR-0004): the MPEG-2 re-encode preserves
  field order; the real open-GOP risk is the leading-picture seam, which is codec-orthogonal.
- **The libav path must remain open.** Decisions from here keep it viable: the export plan is
  expressed as ordered logical segments tagged *copy* vs *re-encode* (with frame ranges), separate
  from their CLI execution, so a libav backend can consume the same plan and add a third
  *re-encode-leading-pictures-only* segment kind; the frame index retains per-frame leading-picture
  structure (not just a boolean) so it need not be rebuilt; and the user-facing model does **not**
  restrict M2 cuts to clean points (M2 cuts anywhere — it only re-encodes more), so no UI/data
  assumption bakes in the CLI-only limitation.

## Amendment — 2026-09-16: `-top` replaced by a scan filter (issue #117)

ffmpeg 9.0.1 removed `top` as an encoding option. Every interlaced re-encode failed to open
its output with *"Codec AVOption top (top field first) is not a encoding option"*. The
requirement is unchanged: a re-encoded piece must carry the source's scan direction.

**What replaced it.** `-flags +ildct+ilme` stays on the encoder — it is what makes the piece
interlaced. The direction now comes from a filter, `setparams=field_mode=tff|bff`, appended
**last** in the video filter chain. ffmpeg 9's encoders read the direction off the frames only.

**House convention.** `reencodeVideoArgs` and `mbaffRepairVideoArgs` carry that filter as a
`-vf` pair inside the encoder argument array. ffmpeg keeps only the **last** `-vf` on an
output. So a builder with its own chain must call `BoundaryReencodeEngine.splitVideoFilter`
and merge the fragment onto the end of that chain. A builder that passes the array through
would drop its own `select` and encode the wrong frames.

**De-risk table.** All runs used `-flags +ildct+ilme`. Sources: real interlaced MPEG-2
MPEG-PS (`field_order=tt`) and a real PAFF H.264 slice. Result is the probed `field_order`,
confirmed at frame level with `interlaced_frame`/`top_field_first`.

| Candidate | mpeg2video | libx264 | Verdict |
|---|---|---|---|
| `-top 0\|1` (old) | fails to open output | fails to open output | removed in ffmpeg 9 |
| `-flags +ildct+ilme` alone | source order kept (tt→tt) | source order kept (tt→tt) | passthrough only; cannot force |
| `setparams=field_mode=tff\|bff` last | tff→tt, bff→bb | tff→tff, bff→bff | **chosen** |
| `setfield=tff\|bff` last | tff→tt, bff→bb | same | equivalent; `setparams` already used elsewhere |
| `-field_order tt\|bb` | accepted, **no effect** (bb→tt) | accepted, **no effect** | silent no-op — a trap |
| `-x264-params tff=0` | n/a | output came out progressive | not pursued |

Containers: .mpg, .ts, .mkv and .mp4, both directions. Chains de-risked in their real shapes —
`select,setpts,setparams`, `select,setpts,fps,setparams`, and the conform tail
`…,setparams=color…unknown,setparams=field_mode=bff` (the colour strip survives; two
`setparams` do not clobber each other, because each option defaults to *auto*).

**Probe trap.** Stream-level `field_order` is container-dependent. MPEG-2 in MKV or MP4 reports
`tb` for top-first. H.264 in MPEG-TS reports `tt` whichever field leads. Frame-level
`top_field_first` is the authoritative probe.

**Why the container decides (issue #119).** ffmpeg 9's `fftools/ffmpeg_enc.c` sets the
encoder's stream-level field order from the first frame's flags, unconditionally: `tb` for
top-first, `bt` for bottom-first, `tt`/`bb` only for MJPEG. That overwrite is also why
`-field_order` is a no-op. Matroska is the one output container that stores the tag, so an
encoder-written MKV probes `tb`, while the same bitstream in MPEG-TS or MP4 — or stream-copied
from either into an MKV — probes `tt`, because those probes come from the parsed bitstream. No
ffmpeg 9 encoder writes a `tt` MKV directly; a `tt` fixture is made by encoding to `.ts` or
`.mp4`, or by stream-copying that into `.mkv`. The spelling therefore says where a stream was
probed, not how it was coded, and `MatchEvaluator.scanDirection` compares direction only.
`MediaProbe.codedFieldOrder` reads the coded frames for the conform gate.

`FieldOrderReencodeIntegrationTests` now **runs** the builders' output and reads the field
order back, in both directions. The string assertions alone let this break reach `main`.

## Amendment — 2026-09-16: the H.264 boundary re-encode is coded interlaced too (issue #119)

`reencodeVideoArgs` gave `+ildct+ilme` and the scan filter to MPEG-2 only, the scope `-top`
had. An interlaced H.264 target's boundary piece was therefore coded as progressive pictures:
in a synthetic 175-frame join, the 25 re-encoded frames probed `interlaced_frame=0` next to 150
interlaced copies, in MKV and MP4 alike. The gate is now `interlaceCapable` — MPEG-2 and H.264.
libx264 honours the flags (frame-level `interlaced_frame=1`, direction from the filter, both
directions, `.ts`/`.mkv`/`.mp4`). libx265 accepts them and ignores them; the project assumes
an HEVC clip is never interlaced, so HEVC gets neither.
