# Every piece of one output is encoded at the join's reorder depth, never flattened to one

A joined video's **reorder depth** is how many frames a decoder must hold back to emit them in
presentation order (ffprobe `has_b_frames`): 0–1 for a simple B-frame cadence, 2 once B-frames
reference other B-frames — a *B-pyramid*, which is both libx264's and libx265's default.

Matroska stores **no DTS**. A block carries one timestamp, the presentation time, so a reader
has to reconstruct decode order itself — and it does that with a reorder queue whose depth it
latches **once**, from the first piece, when it opens the file. Every piece of an MKV join
therefore has to agree on one depth, and the first piece is the one that declares it.

When they disagree, a piece needing a deeper queue than the file declared is read with
**non-monotonic DTS**. Two things then go wrong, both silent:

- the next stream-copy mux — the audio rebuild, which re-reads the joined video with
  `-c:v copy` — bumps the backwards DTS forward to keep them monotonic and drags the PTS along
  with them, collapsing pairs of frames onto a **duplicate timestamp**;
- the decoder emits that piece's frames **early**, so content lands on the wrong timestamps
  even where the timestamps themselves look plausible.

Measured on real 1080p50 HEVC footage (issue #106): a depth-1 conform piece followed by a
depth-2 re-encode gave 220 duplicated PTS in 1100 frames, all of it after the conform piece —
frame count, duration and audio were perfect, which is why a duration or frame-count check never
saw it. The same shape with a *copied* deep piece gave 71 duplicated PTS in 400 frames, and
comparing frame hashes at matching PTS showed ~a third of the tail's frames sitting on the wrong
timestamp.

TS and MP4 carry a real DTS per frame and are immune; this is a Matroska-only constraint, and the
one container this app's footage most often lands in.

## Decision

**Match the depth to the join; never flatten it to a constant.**

The bar is set by the pieces the app *cannot* change: a stream copy carries its source's depth
verbatim — that is what lossless means. So the join's depth is the deepest depth any copy piece in
that output will carry (`ExportEngine.joinReorderDepth`), and every piece the app **encodes** —
conform re-encodes (ADR-0011) and smart-render boundary re-encodes (ADR-0009) alike — is produced
at that depth: the encoders' default pyramid for a deep join, `b-pyramid=0` for a shallow one
(`EncoderSelection.reorderDepthParams`). MPEG-2 has no pyramid and is always shallow.

One refinement, because an item's own first piece may be a copy: a re-encode inside such an item
matches **that item's source** depth rather than the join's, so it can never out-deepen the copy
piece standing in front of it (`ExportEngine.pieceReorderDepth`). Only when the item's first piece
is one the app encodes — a conform, or a plan whose first segment is a re-encode — is the join's
depth the right thing to declare, because that piece is then what the join latches.

## Why not the alternatives

- **Flatten everything to depth 1** (the obvious reading of the bug — "the deep piece is the odd
  one out"). This is wrong, and measurably so: a copy piece keeps its source's depth, so a
  shallow re-encoded head in front of a deep copied middle breaks the join the other way. It also
  breaks the *common* case — most modern H.264/HEVC sources are depth 2 — where today's
  pyramid-by-default re-encode happens to be correct. 25 duplicated PTS in a 300-frame synthetic
  single-clip cut, where the shipped behaviour is clean.
- **Leave the pyramid on everywhere** (declare 2 always). Breaks the case ADR-0011 originally
  fixed: a shallow copy piece first — an MPEG-2 broadcast capture — with a deep conform after it.
  Depth has to follow the footage, not a constant. ADR-0011's `b-pyramid=0` was the right recipe
  for the join it was measured on, and stays exactly that under this rule; it was never a global
  truth.
- **Write the final MKV in one pass** (feed the concat list straight to the audio mux, so nothing
  re-reads a joined MKV). This removes the duplicate PTS — measured — but not the defect: the
  written file still declares one depth, so *other* tools reading it still get frames early. It
  fixes our symptom and ships a landmine.
- **Re-encode copy pieces so depths agree.** Destroys the point of the app.

## Consequences

- `VideoProperties.reorderDepth` is probed (`has_b_frames`) and carried to the engine on
  `ExportItem.sourceReorderDepth`. It is **not** a match dimension: it says nothing about how a
  clip looks, only how deeply its decode order is shuffled.
- The depth decision is join-wide, so it lives where the whole join is visible — `ExportEngine`,
  next to `pieceExtensions`, which layers a per-output rule over a per-item one for the same
  reason (ADR-0024). The engines take the depth as an argument and stay pure builders.
- Clip Doctor's repair joins re-encoded spans with copies of one source, so it matches that
  source's depth. Its field-coded MBAFF tail is exempt: that recipe pins its own encoder
  parameters, and its single copy head is always the join's first piece.
- What the app cannot fix, it says out loud: when the first clip's own **copied** frames are
  shallower than a later clip's, no encoder setting helps, so the export warns, naming the clip to
  put first and offering MP4/TS as the container that records depth per frame
  (`ExportPlanner.reorderDepthWarning`).
- Every re-encode's timestamps are still checked before it ships (`ExportEngine.timestampDefect`),
  but that gate reads a piece **alone**, where its own depth always applies — it cannot see a
  disagreement between pieces. The integration regression tests assert on the **final** file's
  timestamps for both directions: a shallow join (conform + a fully re-encoded clip) and a deep
  one (an interior cut on a B-pyramid source).
