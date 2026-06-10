# Splitting replaces the clip with N clips — no multi-range clip model

Splitting a clip in the cut-editor (split points dividing the selection range into split
ranges) is resolved entirely at confirm time: the original clip is replaced in the timeline
by one clip per split range, each an ordinary clip with its own in/out pair on the same
source file. We deliberately did **not** give `Clip` a list of kept ranges.

## Considered options

- **Multi-range clip**: one timeline row per source file, holding several kept ranges.
  Rejected: it breaks the one-range-per-clip invariant that export windowing (the
  pts − start_time seek of issue #3), the output preview's segment stitch (ADR-0012),
  persistence, and undo all
  assume — every consumer of `inPoint`/`outPoint` would need a ranges loop — and it makes
  reordering or deleting an individual range *harder*, since ranges inside a clip have no
  row to drag or select.
- **Clip replacement** (chosen): split is a cut-editor gesture, but the project model never
  learns a new concept. The resulting clips reorder, delete (batch, issue #12), retarget,
  and export exactly like any other clip. Mirrors TMPGEnc Smart Renderer, where confirming
  replaces the original clip with the split results in the clip list.

## Consequences

- The first split range keeps the original clip's identity (ID), so a split target clip
  stays the target and per-clip caches stay warm; later ranges are new clips that copy the
  probed properties, audio track selections (ADR-0014), and source bookmark.
- Adjacent split-result clips left in order are contiguous frames of the same source, yet
  export treats them as separate clips: a boundary re-encode at each split join (audio is
  rebuilt regardless, ADR-0010). Accepted for now — splitting exists to delete or reorder,
  where that join is unavoidable. Fusing contiguous kept windows at export is a possible
  later optimization and changes no data model.
- Split points themselves are transient cut-editor state, never persisted in the project:
  after confirm they have become clip boundaries; cancel discards them.
