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
  SAR (`setsar`), color primaries/transfer/matrix/range (true color-aware conversion — the
  color stage below), and scan type
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
**Amended (issue #48 / ADR-0020):** when a damage zone reaches the kept window's end (EOF
truncation), the ±1 gate additionally allows a shortfall as deep as the trailing zone — the fps
fill stops at the last decoded frame, and the container's claimed duration can overshoot the
decodable content (the 1844 capture's TS headers do, by ~0.2 s). Exact ±1 everywhere else.

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
- The color stage (issue #35, below) converts toward a *tagged* target and strips toward an
  *untagged* one; the YUV **matrix** (ffprobe `color_space`) joins primaries/transfer/range as
  a fourth color match dimension — in the strict `MatchEvaluator.videoMatches` too, since a
  matrix-only difference between stream-copied neighbours is a visible color shift at the
  join, the exact glitch strict matching (ADR-0005) exists to prevent. A clip differing only
  in matrix now deliberately routes to conform instead of smart render.
- Conform encodes **disable B-pyramid** (`b-pyramid=0` for libx264/libx265; MPEG-2 has none).
  libx264's default B-pyramid lets B-frames reference other B-frames, yielding a decode order
  whose DTS is non-monotonic. The conformed piece probes clean, but after the concat that
  reordered DTS reaches the final stream-copy mux, and **Matroska enforces monotonic DTS by
  nudging the backwards values forward — collapsing pairs of frames onto a single PTS** (the
  duplicate/gapped-timestamps bug). TS tolerates it, so the `.ts` shell de-risk hid it: this
  surfaced only when probing the real **MKV** output. Disabling B-pyramid keeps the decode-order
  timestamps monotonic from birth (one level of B-frames is retained for compression), so the
  conformed clip survives the MKV `-c:v copy` unchanged. Verified end-to-end on H.264 and HEVC.

## Color stage (issue #35)

Conforming toward a **fully color-tagged target** (primaries, transfer, *and* matrix all
probed; range defaults to limited `tv`) performs a true colorspace conversion — pixels
change, not just tags. Toward a fully **untagged** target the long-standing `setparams`
strip is unchanged. A target tagged on only part of the triple gets neither (a converter
cannot aim at a partial spec); its conform still fails self-verify loudly, as before.

- **Filter:** ffmpeg's `colorspace` (not zscale — the toolchain's ffmpeg has no libzimg,
  and `colorspace` covers the SD/HD SDR domain including the 10-bit HEVC pixel formats).
  It always uses the **individual** `space=/primaries=/trc=` options, never an `all=`
  preset: real targets are hybrids — the France 2005 fixture probes bt709
  primaries/transfer with a bt470bg (BT.601) matrix, which no preset describes. The stage
  sits after `format=` and before the fps/interlace tail, so it runs on progressive frames.
- **Untagged sources get an assumed input spec** (a converter cannot read "unknown"):
  ≤ 576 active lines is BT.601 — the 625-line variant (bt470bg/smpte170m/bt470bg) for the
  25/50 fps family, the 525-line variant (all smpte170m) for 30000/1001-family rates — and
  anything taller is BT.709. Probed fields always win over the heuristic, per field. The
  assumption is surfaced as an export warning naming the clip and the assumed standard.
- **No gratuitous conversion:** a source whose (probed or assumed) spec already equals the
  target's skips the conversion. A fully-probed match adds nothing; an *assumed* match adds
  a `setparams` tag-only stage instead. That tag-only stage is load-bearing: ffmpeg 7+'s
  filter-graph color negotiation treats the encoder's `-colorspace`-family flags as
  conversion *requests*, so untagged frames reaching the encoder would be auto-converted
  using ffmpeg's **own** input guess rather than ours (shell-proven: an untagged 601 source
  "retagged" bt709 via flags alone shipped real 709 bytes). Pinning the frame props makes
  the flags a byte-stable identity (also shell-proven).
- **The encoder writes the VUI explicitly** (`-color_primaries/-color_trc/-colorspace`,
  alongside the existing `-color_range`) whenever the target is fully tagged, rather than
  relying on frame-prop propagation alone.

De-risk evidence (all in the real MKV and MP4 output containers): untagged-SD→France and
untagged-HD-10-bit→France on libx264, France→tagged-601 interlaced MPEG-2, France→tagged-709
10-bit HEVC; a solid-color pixel proof that conversion shifts YUV bytes to the textbook
601→709 values while RGB under each side's correct interpretation stays equal; and byte-stable
skip paths. The tagged→untagged strip command is pinned byte-exact by the existing unit tests.
