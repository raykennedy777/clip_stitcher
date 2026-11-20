# In-band parameter sets across joined pieces and silent-decode verification

The concat demuxer emits one video stream with **one** container parameter-set header
(`CodecPrivate` in Matroska, `avcC`/`hvcC` in MP4), taken from the first piece in the concat
list. When a later piece comes from a different encoder run or a different source whose
SPS/PPS/VPS live only in its own container header, decoders parse its slice headers against
foreign parameter sets and produce corrupted pictures — while frame count, PTS spacing, and
duration remain exact (issue #113).

A plain `-xerror` decode does not catch this class either: decoders conceal unparseable
pictures and still exit 0, flooding stderr with parser/reference errors while reporting success.

## Decision

**Every piece joined into a multi-piece output must carry its parameter sets in-band where the
container header cannot be trusted, and every clean piece's verify decode must be silent on
stderr (`requireSilentDecode`).**

- **Re-encoded pieces carry `-bsf:v dump_extra`.** Boundary re-encodes, repaired segments, and
  conformed pieces all append `dump_extra` (`ExportEngine.parameterSetRepeatFilter`) so the
  encoder's extradata is repeated in-band ahead of every keyframe.
- **Clean copied H.264/HEVC pieces carry `h264_mp4toannexb` / `hevc_mp4toannexb`.** Copied
  pieces cannot use `dump_extra` because Matroska/MP4 extradata is an `avcC`/`hvcC` config
  record rather than Annex-B NAL units. MPEG-2 needs neither filter: its sequence headers
  already repeat per GOP in the elementary stream.
- **Exception 1 — sources already repeating SPS + PPS in-band skip `mp4toannexb`.**
  `hevc_mp4toannexb` prepends the container header's SPS ahead of the stream's own in-band SPS
  at every IRAP; when the header SPS differs from the stream's active SPS, the decoder clears
  its reference picture buffer at every CRA and fails RASL pictures (measured: 28 error lines
  per 60 s with the filter vs 0 without on real 1080p50 x265 footage). Before each clean copy
  segment, `BoundaryReencodeEngine.sourceCarriesInBandParameterSets` runs
  `-bsf:v trace_headers -frames:v 1` to a temp stderr file (not `filter_units`, which drops
  packets lacking sets and reads to EOF) and skips `mp4toannexb` when both Sequence Parameter
  Set and Picture Parameter Set appear *after* the first `Packet:` line (past `Extradata`).
- **Exception 2 — damaged sources omit `mp4toannexb`.** Truncated/corrupt pictures choke the
  Annex-B bitstream filter; damaged-source copies keep only the `setts` PTS refill, and repair
  outputs join pieces from one source only (whose re-encoded pieces already carry `dump_extra`).
- **Single `-bsf:v` argument per stream.** ffmpeg silently replaces an earlier `-bsf:v` flag
  when repeated on the same output stream. Encoder argument builders (`BoundaryReencodeEngine`,
  `ClipDoctorEngine`, `ConformEngine`) never emit `-bsf:v`; every segment builder composes all
  filters (`mp4toannexb`, `setts`, `dump_extra`) into one comma-separated `-bsf:v` value.
- **Silent decode gate (`requireSilentDecode`).** On clean sources, `verifyPiece` and
  `verifyConformed` refuse any piece whose `-v error -xerror -f null -` decode prints to stderr,
  even on exit code 0. Damaged sources remain exempt because their decodes legitimately emit
  concealment messages.
- **Cross-clip seams are not verified via windowed seek decode.** Seeking into a short window
  around a cross-clip seam produces false-positive open-GOP leading-picture complaints on `.ts`
  and benign out-of-spec PAFF reference warnings on clean exports; per-piece silent decode
  verification plus in-band parameter sets is the gate for this defect class.

## Consequences

- Multi-piece joins across distinct encodes or sources stay decodable regardless of which piece
  owns the container header.
- Any new bitstream filter added to a segment builder must be composed through the shared
  comma-joined `-bsf:v` builder rather than appended as a second flag.
- Bounded verify windows (ADR-0030) never relax `requireSilentDecode`; a noisy window falls
  back to whole-piece verification.
