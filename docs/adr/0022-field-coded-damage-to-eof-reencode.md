# Field-coded (PAFF) repair is a damage-to-EOF MBAFF re-encode, not a smart-render splice

ADR-0021 left field-coded (PAFF) sources as the open fork: Clip Doctor's first real input
(the 18:42 Polsat capture) is PAFF, and whether the field-aware repaired-segment recipe could
splice cleanly in TS had to be decided in the shell before Swift. ADR-0020 kept PAFF
warn-only for the same reason. **It does not splice. A no-IDR PAFF source cannot be
smart-render repaired in this toolchain** — proven exhaustively on a real PAFF slice (issue
#54, Phase 1). So Clip Doctor repairs a field-coded source by copying the clean head
byte-for-byte up to the keyframe before the first damage, then **re-encoding everything from
there to EOF as MBAFF H.264** — the *damage-to-EOF* repair. It keeps exactly one copy→re-encode
transition (the entry), drops + frame-fills every damage zone in the one continuous tail, and
preserves scan order, resolution, rate, and SAR. High-quality (CRF 18, visually lossless) but
**not bit-for-bit identical** for the re-encoded portion, and slow on a long capture — so the
sheet warns up front and requires an explicit opt-in (issue #54), distinct from the silent
progressive Repair.

## Why smart-render is structurally impossible for no-IDR PAFF (do not re-litigate)

1. **No localized in-place repair exists.** A pure-copy hole-fill fails: there is no
   all-intra/IDR frame to freeze on, and a copy-domain drop-splice ships overlapping/fabricated
   DTS (passes a naive decode grep, fails a strict DTS-monotonicity check). Ruled out by
   *structure*, not tuning.
2. **The MBAFF→PAFF resume seam is a hard container-layer wall.** A bracketed 3-piece splice
   (copy head + MBAFF damage window + copy tail) always fails at the resume seam: the resuming
   PAFF span's B-field DTS collides with the preceding MBAFF segment's DTS, the demuxer sets
   `AV_PKT_FLAG_CORRUPT`, and `-xerror` aborts. No hardening fixed it (forced-IDR, ref/level
   match, SPS/PPS repeat, AUD insertion, discontinuity/genpts/igndts/copyts). **At most one
   copy↔re-encode transition is allowed, and it must be the entry, never a resume.**
3. **This ffmpeg build has no PAFF-capable H.264 encoder.** libx264 is MBAFF-only (one packet
   per frame, `mb_adaptive=1`); `fake-interlaced` is progressive-flagged; h264_videotoolbox is
   progressive-only. So a matched-PAFF repair segment can't be produced, which forces the MBAFF
   island and the unfixable resume seam above.

The only repairs that decode `-xerror` clean from start to EOF *and* show monotonic DTS are
**damage-to-EOF** (chosen — preserves the clean head losslessly, saves time proportional to how
late the first damage sits) and a **full re-encode** (rejected — re-encodes the lossless head
too; damage-to-EOF degenerates to it only when the damage is early).

## How it is built

- **Plan transform** (`ClipDoctorEngine.damageToEOFPlan`): the whole-file smart-render plan is
  collapsed to one copy `[0, seam)` + one re-encode `[seam, EOF)` carrying every video-affecting
  zone. **The seam is snapped to the keyframe at/before the planner's first-repair start.** The
  planner's start is a leading-picture-adjusted copy *end* (`keyframe − n_leading`), correct for
  a segment-muxer DTS cut but not a keyframe; `-segment_frames` there would split at the *next*
  keyframe and overlap the tail, so the seam must land on a real keyframe where the head's copy
  ends and the tail's forced IDR begins — adjacent, no overlap, no gap.
- **MBAFF tail encoder** (`BoundaryReencodeEngine.mbaffRepairVideoArgs`): `libx264 +ildct+ilme`,
  `-top` from `field_order`, **`-crf 18` fixed** (visually lossless, ~1.33× source bitrate — a
  fixed engine constant, not a user control), `-forced-idr 1` + `open_gop=0` for the clean entry
  IDR, `ref=5:level=4.0` matching the source's out-of-spec 5-ref cadence, `b-pyramid=0` (the
  issue-#2 MKV/TS duplicate-PTS collapse), `keyint=25:scenecut=0`, `dump_extra` to
  repeat SPS/PPS into the stream.
- **Audio, staging, and the auto-verify verdict are unchanged from ADR-0021.**

## Verification gates this changes

- **The PAFF piece bypasses the standard `verifyPiece` gate** (`fieldCoded` flag), keeping only
  the from-start `-xerror` decode-to-EOF check. The frame-count check can't reconcile a PAFF
  copy head (two field packets per displayed frame) with the MBAFF tail (one), and
  `timestampDefect` reads the head's 0.02 s field cadence as duplicates against the tail's
  0.04 s median — both false-fail a correct piece. The decode check catches the one failure
  mode this repair can have (a corrupt copy→MBAFF entry seam), and the **post-mux re-scan**
  (ADR-0021's headline verdict) is the real correctness backstop: duration preserved, zero
  zones.
- **The concat seam-closing duration directive is omitted for the PAFF head.** It is
  `pts[hi] − pts[lo]`, exact only for a presentation-ordered uniform index; PAFF's
  reorder-interleaved sub-frame field PTS make it over-estimate the head's display span and open
  a gap at the seam that the re-scan reads as fresh damage. The reset-timestamp copy head's own
  container duration is its true span, so the demuxer places the tail on it.
- **The "non monotonically increasing dts to muxer" line the null muxer prints on field-coded
  rescale is benign** (exit 0, de-risked); real DTS is monotonic once muxed to the container.
  Verify DTS by muxing to the real container, never by trusting the `-f null -` warning.
- **The "corrupt-to-EOF avalanche" on a from-start decode is a reference-state artifact**, not
  the true damage extent — a seek-anchored decode from a nearby clean keyframe recovers in ~1
  GOP. Detection must not treat it as real downstream damage.

## Field-coded repair is H.264-only (issue #57)

The damage-to-EOF route copies the source-codec head byte-for-byte but always re-encodes the
tail as **MBAFF H.264** (`mbaffRepairVideoArgs` hardcodes libx264, and this recipe was only ever
de-risked on H.264 PAFF). The cadence detector that flags a source field-coded is, however,
**codec-agnostic** — it keys off the ~2-packets-per-displayed-frame cadence regardless of codec.
So an MPEG-2 or HEVC source flagged field-coded would concat a `<source-codec>` head with an
H.264 tail into one track: a mid-file codec switch most players can't decode past the seam.

The repair therefore **refuses** a non-H.264 field-coded source
(`DoctorError.unsupportedFieldCodedCodec`) rather than ship the broken concat — and the button/
banner gating (`SourceView.canDoctor`, the import suggestion in `ProjectDocument`) applies the
same `ClipDoctorEngine.canRepairFieldCoded` predicate so such a clip is never offered a repair it
can't do. Real-world captures here are H.264, so the trigger is narrow, but the engine no longer
fails open for it. A whole-file single-codec re-encode for other codecs was considered and
deferred: ADR-0022's recipe is H.264-proven only, and refuse-for-now is the conservative match to
the field-order stance (issue #60).

## Field order is measured, not assumed (issue #60)

The MBAFF tail's `-top` flag must match the source scan order, or the whole damage-to-EOF tail
is field-reversed (combing/judder on motion) — and the auto-verify re-scan does *not* inspect
field order, so it would still report **clean**. The encoder originally derived `-top` straight
from the probed `field_order`, defaulting anything that wasn't an explicit `bb`/`bt` (including a
missing or `unknown` label) to top-first. That fails silently-wrong for a bottom-first source
whose label is absent.

So: a **definite** probed `field_order` (`tt`/`tb`/`bb`/`bt`) is trusted as-is — the fast path,
no extra decode, and the case the real labelled captures take. When it is missing/`unknown`/
unrecognised, the order is **measured** with a short `idet` pass and only used when one polarity
clearly dominates a mostly-interlaced sample (≥ 90 %); otherwise the repair **refuses**
(`DoctorError.fieldOrderUndetermined`) rather than guess — consistent with the conservative
H.264-only guard (issue #57). De-risked in the shell on the real PAFF capture: `idet` reports TFF
unanimously (501/501 at the head, 801/801 mid-file), matching the metadata `tt`; the summary logs
at `-v info` (suppressed at `-v error`) and lands in `ProcessRunner`'s trailing tail.

## Layering: the specialization stays in Clip Doctor (issue #58)

A code review of this work asked whether the damage-to-EOF specialization should move *up*
into the shared planner. Two pieces were examined and both were **deliberately kept where they
are**:

- **Damage-to-EOF is not an `ExportPlanner.VideoTreatment` case.** `VideoTreatment` is the
  join/conform export's verdict (`smartRender` | `conform`), switched over by `planItem` and
  `copyShare`. That path **can never field-code** — a field-coded source can't be cut or joined,
  only doctored — so a `.damageToEOF` case would force those call sites to handle a verdict they
  can never receive: a dead branch in a general-purpose type carrying a Clip-Doctor-only concept.
  Damage-to-EOF is a Clip Doctor word (see CONTEXT.md), so the transform lives in
  `ClipDoctorEngine`. The one real risk the review named — the plan and its MBAFF encoder being
  set in separate statements and drifting apart — is closed by `ClipDoctorEngine.fieldCodedRepair`,
  which returns the `(plan, encoder)` pair atomically.
- **The verify-bypass stays a caller-supplied flag, not a plan-shape inference.** `verifyPiece`'s
  frame-count and timestamp gates are skipped for the field-coded piece via a `fieldCoded` flag
  threaded into `produceVideoPiece`. The review suggested deriving the skip from the plan's
  segment shape instead, but the gates false-fail for a reason invisible in the plan: the copy
  head is PAFF (two field packets per displayed frame) while the MBAFF tail is one — a *media
  format* property of the source. A progressive repair plan has the identical copy-head +
  re-encode-tail shape and its gates **must** still run, so shape can't distinguish the two. The
  flag names the true cause; it is kept.

## Consequences

- **Field-coded clips are now full Clip Doctor inputs.** The Source action button, context menu,
  and import banner enable them; the row's field-coded warning now says only cutting/joining
  remain unsupported (Clip Doctor can repair). `DoctorError.fieldCoded` is removed.
- **Time cost is surfaced, measured-backed:** ~1 h typical for the 4.8 h capture, up to ~5 h on
  a slow/busy Mac (~4.5× realtime typical, down to ~1×); the sheet scales the estimate off the
  clip duration and shows a live time-remaining label during the run.
- **Damage-to-EOF degenerates to a full re-encode when the first damage is early** (the
  acceptance file's first zone is at 883 s of 17 265 s → ~95% re-encoded). That is accepted: the
  saving is real for a file damaged late, and there is no cheaper structurally-possible repair.
