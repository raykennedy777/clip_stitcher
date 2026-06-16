# Audio-only inputs / audio-only projects

clip_stitcher does not support importing files with no video track (MP3s, radio
recordings, audio elementary streams) or building audio-only projects around
them. A clip whose probe finds no `v:0` is rejected at import ("No video
track"), and that stays the intended behavior.

## Why this is out of scope

It's a video app. The entire pipeline is video-frame-based by design: the cut
editor decodes and displays video frames for in/out selection, the per-clip
frame index is built from `v:0` (ADR-0006), and target matching / smart
rendering are defined in video terms (ADR-0005). First-class audio-only inputs
would need a parallel design for each of those — a waveform or time-based trim
editor, audio-only matching rules, and a real audio container mux (MKA/M4A) for
multi-track output. That's a second product, not a feature.

The half of issue #1 that had real value shipped long ago: **audio-only export
of video projects** (`OutputType.audioOnly`, commit `421e925`) produces a valid
elementary audio file in the target codec, verified on all three formats. The
known one-track cap on those exports (elementary streams carry a single stream,
ADR-0014 note) stands as accepted behavior; if multi-track audio-only export of
a *video* project ever becomes a real need, that's a new, narrower issue — not
a reopening of audio-only inputs.

Decided by the maintainer during triage on 2026-06-11: "It's a video app —
this issue would've been covered when audio-only export was implemented ages
ago."

## Prior requests

- #1 — "Support audio-only projects (OutputType.audioOnly path)"
