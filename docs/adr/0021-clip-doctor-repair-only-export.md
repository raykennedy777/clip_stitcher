# Clip Doctor is a repair-only export that produces, and proves, a standalone clean file

Every export already repairs a clip's damage zones in flight (ADR-0020), but that repair is
trapped in one output and the user gets only a "Repaired N zones at …" *report* — a statement
that the recipe was applied, not proof the result is clean. On a multi-hour broadcast capture
nobody scrubs three zones to check. **Clip Doctor** is a clip-specific, repair-only export
that writes a full-length repaired copy of one damaged source in its own codec and container,
then re-runs damage detection on that output and shows the *verdict* as the headline — clean
(zero zones) or a soft warning naming any zone that survived. It is the answer to "did the
repair actually work?", which the implicit export-time repair cannot give.

The repaired copy is a **whole-file smart render**: bit-identical stream copy everywhere,
re-encoded repaired segments only across damage zones (the ADR-0020 machinery with the range
set to first-frame→last-frame instead of a kept selection), audio rebuilt in the source's own
codec with gap silence-fill (ADR-0014, source codec instead of target). The defining
guarantee is the acceptance test made visible: **a doctored file must re-import clean — zero
damage zones, video and audio.**

## Considered options

- **Standalone clean file (chosen).** Repair once, prove it, reuse/archive the result. The
  only option that closes the verification gap and survives outside the project.
- **Per-project in-place repair.** Rejected: duplicates the repair every export already does
  and produces nothing the user can verify or keep.
- **Repair preview/inspector only.** Rejected: it shows damage but produces no artifact, so
  it answers neither "give me a clean file" nor "prove this one is clean."

## Consequences

- **Field-coded (PAFF) sources are the open fork.** ADR-0020 keeps PAFF warn-only because the
  field-aware repaired-segment recipe is unproven. Clip Doctor's first real input (the 18:42
  Polsat capture) is PAFF, so the shell de-risk must prove field-pair-aligned copy boundaries
  and an interlaced re-encode seaming cleanly in TS. If it proves out, field-coded sources get
  smart-render repair; if the seams are unworkable, field-coded sources fall back to a full
  interlaced re-encode (lossy, slow, but seamless). This is decided in the shell, before Swift.
- **Soft failure, never discard.** A surviving zone yields a warning verdict, not a discarded
  file — the user may trim around the unrepairable part and still use the rest. The surviving
  zone keeps badging, which is exactly the cue showing where to trim.
- **Video + audio only.** Subtitle/teletext/data streams are not carried into the repaired
  file (consistent with the rest of the engine, which models only video + audio tracks), and
  their omission is surfaced in the sheet, never silent. Passthrough is deferred indefinitely.
- **Never overwrites the source.** Output defaults to a sibling `_repaired` file, staged via a
  same-volume temp and atomically moved only on success — the damaged original is the sole
  source of every copied-through frame and of the damage itself, so it is never at risk.
- **Same container in, same container out.** Avoids the container-rehousing traps (timescale,
  timebase, start_time) that would silently shift damage-zone times on re-import; requires the
  smart-render concat to emit a clean transport stream (continuity counters, PCR), proven in
  the same de-risk.
