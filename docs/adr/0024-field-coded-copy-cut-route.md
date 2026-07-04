# Field-coded (PAFF) H.264 gets a copy-cut route: snapped marks, copy-only plans, forced `.ts` pieces

ADR-0022 proved that a no-IDR field-coded (PAFF) source cannot be smart-render repaired —
the MBAFF→PAFF resume seam is a hard container-layer wall — and left cutting/joining such
clips unsupported (CONTEXT.md's old "Field-coded (PAFF)" entry, issue #46). Issue #96's
shell de-risk, run on a developer-supplied field-coded H.264 capture with the engine's
exact segment-muxer recipe, showed that question was narrower than it looked: a **pure
stream copy** cut at a leading-picture-free keyframe is frame-exact on PAFF exactly as it
is on progressive footage, and a copy cut can *end* at an open-GOP keyframe too, by
discarding that keyframe's leading fields into the cut segment (the same asymmetric
boundary rule `CopySafeBoundaryDetector` already applies for progressive clips, #16). So
where ADR-0022 closed the re-encode door, this ADR opens a **copy-only** door: an H.264
field-coded clip's cut/join marks now snap to the boundaries a pure copy can legally land
on, trading exact frame accuracy (marks may move up to about one GOP) for a lossless,
lossless-throughout export. Non-H.264 field-coded clips have no validated recipe and stay
warn-only; progressive clips are untouched.

## Why copy-only, never re-encode (ADR-0022 still holds)

Nothing here reopens ADR-0022: frame-accurate smart-render repair of a no-IDR PAFF source
is still structurally impossible, and re-encoding a field-coded *cut* boundary would hit
the identical resume-seam wall the moment the kept range didn't already start and end on
copy-safe keyframes. The copy-cut route sidesteps the wall entirely by never re-encoding a
field-coded segment for a cut/join: every mark is pre-snapped so the planner's normal
partial-GOP `.reEncode` edges vanish by construction, and the planner enforces that
invariant as a backstop rather than trusting the snap alone (see below).

## Snapping rules (`CopyCutSnapper`)

Pure frame-number logic, kept out of the clip model so it is testable without a real clip:

- An **in-point or split point** may sit only on a leading-picture-free ("copy-safe")
  keyframe (count 0) — a copy may *start* nowhere else, or the seam would orphan that
  keyframe's leading fields.
- An **out-point** may sit at `k − leadingCount − 1` for *any* counted keyframe `k`
  (inclusive index): the segment-muxer cut just before `k`'s DTS keeps exactly the frames
  through that index and drops `k`'s leading fields on the discarded side, so even an
  open-GOP keyframe legally *ends* a copy.
- "Nearest" is by frame distance; an equidistant tie keeps the requested frame **inside**
  the kept range, so a snap never silently drops the frame the user parked on when it
  doesn't have to.

Measured on the de-risk capture: copy-safe keyframes 60.52 s and then 1.40 s apart, with an
open-GOP keyframe carrying 6 leading fields 120.52 s later — the snap distances a real edit
session will see are on that order, not arbitrary.

## The export plan is copy-only by construction (`ExportPlanner`)

`videoTreatment` takes a new `PlanPurpose` (`.export` vs `.repair`). On `.export`, a clip on
the copy-cut route (`FieldCodedSupport.requiresCopyOnlyCuts`) withholds its damage zones —
damage copies through **verbatim**; copy-only cutting doesn't repair, and the documented
workflow is Clip Doctor first when a kept range crosses damage. With damage withheld, the
snapped marks make every partial-GOP `.reEncode` edge vanish by construction, so if a
`.reEncode` segment appears anyway the plan throws `ExportError.fieldCodedPlanNotCopyOnly`
— a programming-error backstop (stale marks, a snapper bug, a path that bypassed snapping),
never a fallback route. `.repair` (Clip Doctor's whole-file pass) is exempt: it keeps the
damage `.reEncode` segments on purpose — they are exactly what `ClipDoctorEngine.fieldCodedRepair`
collapses into ADR-0022's copy-head + MBAFF-tail plan.

## Stale marks re-validate at the `reconcileInOut` funnel

`reconcileInOut` now takes the fresh `FrameIndex` (previously just a frame count) and runs
two checks in order: the existing range check (`validatedInOut`, issue #74), then — for a
clip the fresh probe confirms is on the copy-cut route — `snappedInOut`. Marks set before
`fieldCoded` resolved true, a pre-#96 saved project, or a relink's re-probe all land here
and re-snap; an unsnappable point (no valid boundary) or a snapped pair that crosses resets
both to nil (whole clip), mirroring `validatedInOut`'s reset semantics, so an unsnappable
mark can never reach the planner's copy-only gate. Every change queues the existing
`inOutResets` notice (generalized in `SourceView` to cover both reasons) — never silent.

## Pieces are always cut as `.ts`; a whole-clip keep stays on the plain remux path

Matroska stores no independent DTS: cutting a field-coded piece as `.mkv` made the concat
demuxer regenerate DTS from PTS and collapse the B-field PTS dips into duplicates
(measured: ~3030 anomalies over a 3-minute copy cut in the shell de-risk; reproduced in the
mixed-join integration test as 998 frames collapsed onto duplicate PTS). TS pieces carry
real DTS and were validated clean feeding TS, MKV, *and* MP4 finals. So a field-coded
clip's cut pieces are always produced as `.ts` regardless of the output container
(`ExportEngine.pieceExtension`); a clip **kept whole** (`isWholeClipCopy` — one copy
segment, no head/tail cut) stays on today's plain-remux path in the output container,
byte-for-byte unchanged, since there is no piece boundary for MKV's DTS regeneration to
collapse.

This session's shell de-risk extended the rule to **joins**: a multi-clip connect join
containing *any* field-coded item forces **every** video piece in that join — other
clips' cuts, whole-keep remuxes, and conform re-encodes alike — to `.ts`
(`ExportEngine.pieceExtensions`). A mixed-container concat list was measured dirty: an MKV
piece's duration, re-read in a neighbouring `.ts` piece's 1/90000 timebase, misplaced the
following piece by roughly 90× its true offset (a 39.9 s piece pushed its neighbour to
~3593 s), and the reversed clip order collapsed the MKV piece's 998 frames onto duplicate
PTS. All-`.ts` lists were clean in TS, MKV, and MP4 finals, in both clip orders.

## Concat duration directives are per-entry

The cross-clip concat list (`ExportEngine.crossClipDurations`) keeps the issue-#6 /
ADR-0008 seam-closing `duration` directive for every progressive entry unconditionally —
dropping it for one field-coded item in the join would reopen that seam gap for every
*other* clip — but emits **none** for a field-coded entry. A cut field-coded piece's
directive would be an exact no-op (`pts[hi] − pts[lo]` matched the mpegts-reported span
exactly: 60.52 s over the validated 3026-field piece), but a **whole-keep** field-coded
piece's directive is `ExportEngine.clipSpan`'s mean-interval estimate, which under-states a
ragged-tail broadcast capture's true content span — the too-short directive overlapped the
next clip into the tail and produced a duplicate video PTS in the MKV final. The
directive-free entry seamed at exactly one field step (0.02 s) instead. Since every
field-coded entry is a `.ts` piece by the rule above, and a `.ts` piece self-reports its
true content span, omitting the directive is safe and lets the demuxer's own placement do
the work.

## Decode verification judges by exit code, never stderr emptiness

A field-coded copy-cut piece is verified by a full `-xerror` decode pass, judged **only by
exit code**. A recovery-point (non-IDR) entry into a copy-cut piece prints benign
`mmco`/reference-frame warnings even at `-v error`, so a stderr-emptiness check would
false-fail a correct piece; entry was independently confirmed pixel-perfect from frame 1
(md5 against a warm decode) in the de-risk. The frame-count and timestamp gates
`verifyPiece` runs for ordinary cuts are skipped for the same reason ADR-0022 skips them
for the damage-to-EOF piece: they assume one packet per displayed frame, and a field-coded
piece's 0.02 s field cadence reads as duplicates under that accounting.

## Known limit: a field-coded piece following a progressive piece fails decode (recorded, not fixed here)

In a mixed connect join, field-coded-first (or field-coded-only) is clean. The reverse —
a progressive piece followed by a field-coded piece — fails the `-xerror` gate in every
container shape tried: this capture carries no IDR slice at all, so a copy-cut piece can
only *enter* on a recovery-point (non-IDR) keyframe, and following foreign (progressive)
decoder state, the recovered frames decode flagged corrupt. This is a content-level seam
wall in the same family ADR-0022 hit for repair (issue #46), not a container or
duration-directive defect, and no combination tried in the shell worked around it.
Planner-level conform-or-refuse for this specific ordering is deferred to a follow-up
issue rather than fixed here.

## One-entry rewrap funnel for a `.ts` piece reaching a final placement

A `.ts` piece that must land as the final output on its own (a single-clip video-only
export, or the video-only leg of a connect join) is rewrapped into the target container
through the same one-entry concat funnel the multi-piece join uses
(`ExportEngine.containerReadyPiece`) rather than a bespoke remux path — reusing the
recipe already proven clean for TS pieces feeding TS/MKV/MP4 finals. A piece already in
the target container passes through untouched, keeping today's plain-move behavior
byte-identical for every non-field-coded export.

## Considered options

- **Copy-only cutting via pre-snapped marks (chosen).** Reuses the existing segment-muxer
  and copy-safe-boundary machinery (ADR-0008/0009) with no new re-encode path; the only
  option consistent with ADR-0022's proof that re-encoding a PAFF boundary is unsafe.
- **Leave cutting/joining permanently unsupported.** Rejected: the limitation was never
  fundamental to PAFF, only to *re-encoding* it — H.264 PAFF copy cuts prove frame-exact,
  and refusing them leaves real footage unaddressable for no correctness reason.
- **Extend the damage-to-EOF re-encode shape to ordinary cuts.** Rejected: damage-to-EOF
  tolerates exactly one copy→re-encode transition (the entry); an arbitrary cut/join needs
  potentially many independent boundaries, each reopening the resume-seam wall ADR-0022
  already proved fatal.

## Consequences

- **H.264 field-coded clips are now cuttable and joinable.** CONTEXT.md's "Field-coded
  (PAFF)" glossary entry no longer says cutting/joining "stay unsupported"; the row warning
  narrows to naming the snap-to-keyframe behavior for H.264 sources and keeps the old 2×
  frame-numbering warning for every other codec.
- **Marks visibly jump on set.** `setIn`/`setOut`/`toggleSplit` move the playhead to the
  landed frame so the snap is never silent; a mark with no valid boundary is a
  non-destructive no-op.
- **Damage inside a cut field-coded clip's kept range is not repaired by the cut** — it
  copies through verbatim. Clip Doctor first remains the documented workflow for a
  damaged field-coded source.
- **Non-H.264 field-coded clips and progressive clips are unaffected** — the former have no
  validated recipe (`FieldCodedSupport.canRepairFieldCoded` is H.264-only), the latter never
  touch this route.
- **Field-coded-then-progressive join ordering is a known dead end**, tracked as a
  follow-up rather than solved here (see above).
