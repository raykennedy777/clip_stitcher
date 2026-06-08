# Milestone 2 boundary re-encode is CLI-only and copies only between leading-picture-free keyframes

The boundary re-encode (engine Milestone 2, ADR-0004) is implemented with the bundled
`ffmpeg`/`ffprobe` CLI binaries only (upholding ADR-0002), with **no in-process libav linkage**.
A frame-exact cut between keyframes is produced by re-encoding from the cut to the nearest
**leading-picture-free keyframe**, stream-copying the keyframe-bounded span between, and
re-encoding from the last leading-picture-free keyframe to the out-point — then concatenating.
The minimal-re-encode, libav-level approach (smartcut-style) is deferred to a **future milestone**.

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
