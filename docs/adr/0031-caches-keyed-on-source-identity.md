# Caches keyed on source identity; a hit skips the encoder, never the gate

The 2026 R16 MotoGP job needed five renders and more plan queries. Each run read every
source again (about 1.5 s per GB of packet scan, plus about 3 s per damage candidate) and
each render re-encoded all 30,127 boundary and conform frames (about 00:10:55 of x265),
though a job edit that moves one Fill changes only a few pieces (R1, R2 of the
post-mortem review, `motogp_muxing/records/motogp/2026/r16_jpn/logs/postmortem/clipstitch_perf_review.md`).

## Decision

**Two opt-in caches, `--index-cache <dir>` and `--piece-cache <dir>`, both keyed on the
source's identity. A cache hit replaces a computation with its stored result and changes
nothing else: the index cache serves exactly the facts a fresh scan produced, and a piece
taken from the piece cache passes the same verify gate as a fresh encode.**

- **Source identity** — real path, size, mtime (ns), inode, SHA-256 of the first and last
  64 KiB. Shared by both caches.
- **Index cache key** — source identity, the `-version` text of ffprobe and ffmpeg, the
  running clipstitch executable (path, size, mtime), and a schema constant. The facts come
  from this binary's parser and detectors, so a rebuild must miss. The frame index is
  stored as raw doubles, so a hit equals a fresh scan bit for bit.
- **Piece cache key** — source identity, ffmpeg's `-version` text, the planned segment
  (kind, range, out-cut keyframe, damage) and the exact ffmpeg argument array with the
  output piece's path replaced by a placeholder. The arguments carry every encoder
  setting, so the key needs no list of them. The output path is out of the key, so a clip
  that moves to another index still hits.
- **Store after the gate.** A boundary piece is stored after its clip's `verifyPiece`
  passes, a conform after `verifyConformed`. A cached piece that fails its gate is
  evicted, so the next render encodes it again instead of failing the same way.
- **Opt-in.** Without the options the run executes the same commands as before, so
  output identity with caches off holds by construction.
- **Copy pieces are not cached.** They cost a stream copy, and their read depends on a
  measured head seek.

## Consequences

- A warm render is stream-identical (framemd5 and packet list) to the cold render that
  filled the cache (`StitchPipelineIntegrationTests`). Whole-file bytes differ in any
  case: Matroska writes a random SegmentUID and a DateUTC.
- A change confined to the middle of a source that keeps its size and mtime is invisible
  to the identity.
- An x265 or x264 library upgrade without an ffmpeg rebuild leaves `ffmpeg -version`
  unchanged, so old pieces still hit. They are valid and verified, but not bit-identical
  to a fresh encode. Delete the piece cache after such an upgrade.
- A change to the join's reorder depth or MP4 timescale re-keys every piece of the join.
- Neither cache is pruned.
