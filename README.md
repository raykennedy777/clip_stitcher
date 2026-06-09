# vid_conform

A macOS app for frame-accurate video joining via **smart rendering** — re-encoding only
the frames at edit/join boundaries while stream-copying everything untouched. Inspired by
[TMPGEnc MPEG Smart Renderer](https://tmpgenc.pegasys-inc.com/en/product/tmsr5.html).

## Goal

Trim clips to arbitrary frames and join them with near-instant, near-lossless output:

1. **Probe** each input (codec, profile/level, resolution, fps, pixel format, GOP, color params).
2. **Classify** each clip's in/out points:
   - On a keyframe → stream-copy (bit-exact, zero re-encode).
   - Between keyframes → re-encode only the partial GOP to the next keyframe; copy the rest.
3. **Concatenate** the resulting segments (stream copy).

The hard part is making the re-encoded boundary segment splice seamlessly with the copied
stream: matching codec profile/level, pixel format, color space/range, bitrate, GOP structure,
and PTS/DTS + audio alignment.

## Approach / references

- [smartcut](https://github.com/skeskinen/smartcut) — boundary-re-encode algorithm (H.264/H.265/VP9/AV1).
- [LosslessCut](https://github.com/mifi/lossless-cut) — reference for the cut/trim GUI UX.
- FFmpeg as the underlying engine.

## Status

The engine is done and verified on MPEG-2, H.264, and HEVC: keyframe-aligned cuts,
frame-exact boundary re-encode, conform of non-matching clips to the target spec, and the
sample-accurate audio rebuild (ROADMAP slices 1–5, ADR-0008…0011). Current work: the output
preview (ROADMAP slice 6, ADR-0012). See `docs/ROADMAP.md` for what's next and `docs/adr/`
for the reasoning.
