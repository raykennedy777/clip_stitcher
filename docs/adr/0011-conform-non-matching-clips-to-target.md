# Conform non-matching clips to the target spec

A clip that fails `MatchEvaluator` (ADR-0005) is **conformed**: its kept range is fully
re-encoded so that, re-imported, it matches the target clip exactly. Conform is the path that
lets clips of different codecs/resolutions/scan-types/color join cleanly with the
smart-rendered matching clips — closing the gap where the `.reEncode` badge was a promise the
engine couldn't keep.

## What conform produces

- **Kept range only**, as a **time window**. The in/out points define a span in source
  presentation time (`pts[inPoint] … pts[outPoint]`), and conform fills that span with frames
  at the *target* frame rate. Because frame rate is a match dimension, conform may change the
  frame *count* (e.g. 50→25 fps halves it); the count is `duration × target_fps`, not the
  source range length. In/out points are deliberately treated as time, not frame count, so
  conformed video stays aligned with the audio — which is already rebuilt as a time window
  (ADR-0010) and would otherwise drift.
- **Every match dimension transformed to the target, never just re-tagged.** Resolution
  (scale), frame rate (drop/duplicate via `fps` — never motion-interpolation, which warps
  fast sports motion), pixel format and **bit depth** (real conversion, e.g. 10-bit→8-bit),
  SAR (`setsar`), color primaries/transfer/range (true color-aware conversion), and scan type
  (`bwdif` deinterlace / `interlace`+field-flags interlace, both directions). Tagging the
  output to match without converting the pixels would pass `MatchEvaluator` while shipping a
  visible color shift or distortion at the join — the exact glitchy splice strict matching
  exists to prevent.
- **Display aspect ratio is preserved.** W, H, and SAR are match dimensions, so DAR
  (= W/H × SAR) is pinned by implication — but a naive `scale=W:H` would *stretch* a clip whose
  DAR differs and still pass the match check. So: when source and target DAR are equal, scale +
  `setsar` (the common SD-anamorphic-16:9 → HD case — no bars); when they differ (e.g. a 4:3
  clip into a 16:9 target), scale-to-fit + **pad** (letterbox/pillarbox). Never stretch, never
  silently crop — for a joining tool the target is the canvas and discarding the edges of the
  footage is a worse surprise than black bars.
- **Audio conformed too.** `sampleRate`/`channels` are match dimensions because the audio
  rebuild concatenates every clip at the sample level (ADR-0010) and that only works when they
  already align. So a conforming clip's audio is resampled/remixed to the target rate and
  channels before it enters the concat; matching clips pass through untouched.

## Verification

A conformed piece **re-probes itself and asserts `MatchEvaluator.matches(piece, target)`**, on
top of M2's `-xerror` decode check (ADR-0008), and fails the export loudly (naming the offending
dimension) rather than shipping a near-miss. The acceptance bar is the runtime guard. The exact
frame-count assertion from M2 is relaxed for conformed pieces — output frames = `duration ×
target_fps` (±1 for boundary rounding), since fps conversion legitimately changes the count.

## Consequences

- `mixedCodecs` (the connect-mode refusal of differing source codecs) is **removed** — conform
  is exactly how mixed codecs are joined, so every piece reaching the concat is the target codec.
  The container-compatibility guards (`streamCopyCompatible`, the MPEG-2-in-MP4 warning) stay.
- Conformed pieces go through the **same concat-demuxer path** as smart-rendered pieces — a
  from-scratch re-encode to the target spec carries different SPS/PPS than the broadcaster's, but
  M2 already concatenates re-encoded GOPs with original copied packets cleanly (ADR-0009); the
  cross-seam decode is proven in the shell on the real clips before any Swift.
- Lives in a new `ConformEngine` mirroring `BoundaryReencodeEngine`, with an optional conform
  descriptor on `ExportItem`; the proven M2 path is untouched. The two engines share surface
  (encoder/profile selection, `timeString`) flagged `TODO(consolidate)` for a later refactor.
