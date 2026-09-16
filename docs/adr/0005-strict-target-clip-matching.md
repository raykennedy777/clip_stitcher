# Strict target-clip matching

A clip is smart-rendered only if it matches the target clip exactly on: video codec, profile,
level, resolution, frame rate, pixel format, scan type + field order, pixel aspect ratio (SAR),
and color primaries/transfer/range; plus audio sample rate and channel count. Any mismatch in
any of these triggers a full re-encode (conform) to the target spec.

Strict matching favors guaranteed-clean joins over maximizing how many clips avoid re-encoding,
because a glitchy splice (color shift, interlacing artifact, audio pop) defeats the entire
purpose of the tool.

**Audio codec is deliberately *not* a match criterion** (removed later; see ADR-0010). The audio
track is rebuilt and re-encoded to the target clip's codec on every export regardless of the
source, so a clip's source audio codec never blocks its video from being smart-rendered. Sample
rate and channels stay match criteria because the rebuild preserves them rather than resampling,
so the sample-level audio concat only works when they already match.

## Consequences

- Clips that are "almost" identical (e.g. differ only in color range) get fully re-encoded.
- **Scan type is compared as a direction** (top-field-first, bottom-field-first, progressive),
  not as ffprobe's four-way `field_order` spelling: `tt` and `tb` are one coded stream probed in
  two containers (issue #119, ADR-0011 amendment). A missing or `unknown` value is progressive.
- Per-property relaxation/overrides can be added later if strict proves to re-encode too eagerly.
- A clip whose video and audio rate/channels match but whose audio *codec* differs is still
  smart-rendered — the round-tripped-export case that motivated removing audio codec (ADR-0010).
