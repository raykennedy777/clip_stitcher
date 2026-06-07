# Strict target-clip matching

A clip is smart-rendered only if it matches the target clip exactly on: video codec, profile,
level, resolution, frame rate, pixel format, scan type + field order, pixel aspect ratio (SAR),
and color primaries/transfer/range; plus audio codec, sample rate, and channel count. Any
mismatch in any of these triggers a full re-encode (conform) to the target spec.

Strict matching favors guaranteed-clean joins over maximizing how many clips avoid re-encoding,
because a glitchy splice (color shift, interlacing artifact, audio pop) defeats the entire
purpose of the tool.

## Consequences

- Clips that are "almost" identical (e.g. differ only in color range) get fully re-encoded.
- Per-property relaxation/overrides can be added later if strict proves to re-encode too eagerly.
