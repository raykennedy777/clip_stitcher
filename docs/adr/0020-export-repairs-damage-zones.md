# Exports repair damage zones with a time-window drop and an fps fill

A clip's recorded damage zones (issue #45) are repaired by every video export path
(issues #47/#48): the zone's span is dropped by a time-window `select` and refilled by
the `fps` stage repeating the last good frame, preserving the source timeline length.
Always repair and report ("Repaired 3 damage zones at …" on export completion) — never
silently ship glitched frames, and never refuse the export. On the smart-render path
each video-affecting zone forces a **repaired segment**: a re-encode extending to the
surrounding copy-safe boundaries (left: a legal copy end at least one frame before the
first damaged frame, so the fill has a hold frame; right: the first copy-safe start past
the damage). On the conform path the `select` rides the existing chain immediately
before its fps stage. A clip with no zones plans byte-identically to before repair
existed, on both paths.

Repaired segments select by **time, not frame number** — at every truncated
no-timestamp packet the index numbering and the decoder's emitted-frame numbering drift
apart by one — with the window times taken from the recorded zones, never re-derived
from index gaps (several real zones are decoder-level holes whose packets are all
present). Validated on all three formats × three containers in the shell, and end to
end on the real 1844 capture across all nine documented zones (issue #47's run record).

## Consequences — verification gates relax exactly where damage makes them wrong

- **Frame counts** (amends ADR-0008/0009's exact gate): a repaired segment's expected
  count is its slot budget — span duration × source fps — not its frame-range length
  (holes filled, corrupt frames dropped and held over). The budget is exact interior;
  only a damage window running through the **file end** allows a shortfall (bounded by
  the trailing window), because the fps end-of-stream flush pads to the last *decoded*
  frame and a truncated final packet sits in the index but never decodes. The conform's
  ±1 gate (ADR-0011) gains the same trailing-zone allowance: the container's claimed
  duration can overshoot the decodable content (the 1844's TS headers do, by ~0.2 s),
  so "duration × fps ± 1" is unsatisfiable at a damaged file end.
- **Timestamp gate** (amends ADR-0008 #19): the piece's outermost edges are no longer
  held to the seam-strict 2-interval window — nothing abuts the first segment's head or
  the last segment's tail *within the piece*, and a whole-file copy legitimately
  reproduces the source's own tail anomaly (the `-t`-cut HEVC excerpt presents a
  B-pyramid hole in its final interval; the old gate made such sources unexportable).
  The source-match requirement still applies there, and interior seams stay strict —
  that is where the shipped defect classes live. At the cross-clip concat a tail
  anomaly can now reach a join, but only as a faithful copy of the source's own
  pattern; rejecting the whole clip was the worse trade.
- **Copy cuts of damaged sources into MKV** carry the issue-#2 `setts` pts refill
  whatever their codec: truncated packets choke the matroska muxer even from
  *discarded* segments (the segment muxer writes those too), so a clean kept window
  still failed on the 1844. Keyed on the clip having zones — clean clips keep
  byte-identical commands.
- Repair spans widen until the next frame's dts clears the zone's max(pts, dts): the
  copy cut resuming after a repair is placed on its boundary keyframe's dts, and
  mis-framed in-zone garbage whose timestamps reach past that cut would be swept into
  the kept copy.
- Field-coded (PAFF) sources stay warn-only (issue #46) — repair presumes the
  packet==frame index (ADR-0006).
