# Corruption repair — fixtures, recipes, detection

Written up from agent memory (issues #43–#48; ADR-0020/0022 hold the decisions;
full records live on those issues). Applies to ffmpeg 8.1.1.

## The two real fixtures (private — never commit, ADR-0023)

- **File 1** — a broadcast `.ts` capture (kept outside the repo):
  H.264 1080p50 progressive + HE-AAC, IDR keyframes, damage stays local
  (9 events, 10 corrupt frames; audio gap accompanies every video damage).
- **File 2** — a second broadcast `.ts` capture (kept outside the repo):
  H.264 1080i25 **PAFF field-coded**, non-IDR recovery-point keyframes,
  garbled PES timestamps + payload garbage (a 39 s dead zone at 8132–8171).
  Decoder state poisoning: a from-start decode flags 43% of frames corrupt,
  but seek-anchored windowed decodes of the same regions are clean, and pixel
  checksums are identical — the avalanche flags are bookkeeping, not damage.

Synthetic fixtures: `scripts/make_corrupt_fixtures.sh` →
`~/Desktop/working/corrupt_fixtures/`.

## Recipes

- **Video — drop damaged window, hold last good frame:** re-encode with
  `-vf "select='not(between(t,DMG_START,DMG_END))',fps=TARGET"` (t relative to
  seek anchor); the fps fill repeats the last good frame and the output is
  exact-duration uniform CFR. `-fflags discardcorrupt` does NOT work — damage
  isn't packet-flagged; windows must come from detection.
- **Audio — fill gaps with silence, survive dead zones:**
  `-max_error_rate 1.0` + `aresample=RATE:async=1:first_pts=0` ahead of the
  existing leg. Without `max_error_rate`, a damaged span aborts at ffmpeg's
  default 2/3 error rate (exit 69, truncated output).

## Detection

One demux pass over ALL streams (video dts gaps / N-A packets / dup-dts + audio
pts gaps in any stream) → candidate zones, then seek-anchored short decode
windows around each candidate → exact corrupt-frame pts via the `corrupt
decoded frame` log + showinfo. NEVER use a single from-start decode pass as the
detector on non-IDR sources (43% false positives on file 2).

Repaired spans: expected counts must become duration×fps, and
`select=between(n,..)` numbering drifts at N-A packets — use time-based select
for repaired spans. MPEG-PS `-ss` is byte-estimated: seek ≥1 GOP early and
bound the span start in the select. Any damaged source → MKV copy cut needs the
issue-#2 setpts pts-refill regardless of codec. Damaged-MKV → TS copy cut
hard-fails in the auto-inserted annexb bsf (issue #50).
