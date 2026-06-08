# Reimplement boundary smart-cut in Swift, smartcut as reference only

The partial-GOP boundary re-encode (Milestone 2 of the engine) is reimplemented in Swift
driving the bundled `ffmpeg`, using the `smartcut` project only as an algorithmic reference —
not as a runtime dependency.

## Considered options

`smartcut` (Python + PyAV) was the obvious reuse candidate and does support MPEG-2 and TS/M2TS.
It was rejected as a runtime dependency because bundling a second toolchain (Python + PyAV) to
sign and notarize, plus debugging across PyAV's opaque internals, conflicts directly with the
single-toolchain, reproducible-ffmpeg-command approach in ADR-0002.

## Consequences

- We own the hardest code in the project, but every step stays inspectable as an ffmpeg command.
- `smartcut`'s interlaced-MPEG-2 behavior is undocumented; interlacing must be tested early
  regardless (see ROADMAP risks).
- How this is actually built — CLI-only, copying only between leading-picture-free keyframes,
  with the minimal-re-encode libav approach deferred to a future milestone — is recorded in
  ADR-0009.
