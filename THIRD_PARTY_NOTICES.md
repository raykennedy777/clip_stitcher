# Third-party software

vid_conform's own source code is licensed under the MIT License (see `LICENSE`).
It relies on the following external software, which carries its own license.

## FFmpeg

vid_conform drives **FFmpeg** (`ffmpeg` and `ffprobe`) as external command-line
tools — it does not link FFmpeg's libraries.

- **In development**, FFmpeg is *not* bundled: the app locates a system install
  (e.g. `brew install ffmpeg`). vid_conform distributes none of FFmpeg's bytes.
- FFmpeg is licensed under the **LGPL v2.1+**, and under the **GPL v2+** when
  built with GPL-only components (e.g. `libx264`, `libx265`). The Homebrew build
  commonly used in development is a GPL build.
- Homepage / source / license: <https://ffmpeg.org/legal.html>

> **Release-bundling note.** A signed release that *ships* an FFmpeg binary must
> resolve FFmpeg's license at that point — either bundle an LGPL build (and meet
> its relink/attribution terms) or license the distributed app accordingly. This
> decision is deferred until a binary is actually shipped and will be recorded in
> an ADR; see `docs/adr/0002-ffmpeg-bundled-cli-binaries.md`.

## References (not distributed)

These projects informed the design but are not bundled or linked:

- **smartcut** — boundary-re-encode approach. <https://github.com/skeskinen/smartcut>
- **LosslessCut** — cut/trim GUI UX reference. <https://github.com/mifi/lossless-cut>
