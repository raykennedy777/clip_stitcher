# Cut-only: a separate-mode rendering choice, target-irrelevant, container still global

"Export separately" gains a rendering choice: **conform to target** (today's behavior —
matching clips smart-render, non-matching clips conform, ADR-0011) or **cut-only** — each
clip is smart-rendered *against itself*: boundary re-encode in the clip's own codec at cut
points, stream copy elsewhere, the target clip playing no role at all. An untouched clip is
a pure remux. The choice lives as a sub-setting of separate mode (a second picker shown only
there), not as a third output mode: cut-only can never apply to connect mode, where joining
requires uniform properties and conform is mandatory.

## Decisions and their trade-offs

- **Container stays global.** Cut-only still writes into the project's chosen container
  (TS/MKV/MP4), with the existing per-codec compatibility warnings applied per clip. A
  per-clip "same as source" container would be truer to "touch nothing", but the engine has
  only de-risked writing the three known containers — emitting arbitrary source containers
  (MPEG-PS, MOV, AVI…) is a large unvalidated muxer surface for marginal benefit. A remux
  is lossless, so the minimum-encoding promise holds. "Same as source" can be a later picker
  option once de-risked.
- **Audio is still re-encoded — to each track's own source.** Audio is never stream-copied
  (ADR-0010/0014); cut-only rebuilds each of the clip's own selected audio tracks to that
  track's source codec/rate/layout. No silence-fill to the richest clip's track count:
  parallel tracks exist for joining, which cut-only never does. If a track's source codec
  has no encoder in the bundled ffmpeg or is invalid in the chosen container, that track
  falls back to AAC at the source rate/layout and the export-done warnings say so.
- **The target designation survives untouched.** In cut-only the target's spec governs
  nothing, but the project keeps its target clip (it matters again the moment the mode
  flips back). The source list shows non-target rows with a "Cut only" badge in place of
  Smart render/Re-encode; the target row keeps its Target badge unchanged, so "Set as
  Target Clip" never appears broken.

## Consequences

- Badge computation (`ClipRowView` roles) starts consulting output settings, which it
  currently doesn't.
- The smart-render path already builds its boundary re-encode arguments from the clip's
  own probed properties (source-matched edges, ADR-0009, via the shared `EncoderSelection`
  tables) — so cut-only's video change is verdict-only: skip the conform branch in the
  export planner; the smart-render machinery needs no changes.
- Cut-only is not a batch uniformizer: two clips with wildly different codecs both export
  untouched-by-conform. Making everything uniform is exactly what conform-to-target
  separate mode is for.
