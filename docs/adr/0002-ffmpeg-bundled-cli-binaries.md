# FFmpeg via bundled CLI binaries, distributed outside the App Store

All probing, cutting, re-encoding, and concatenation is performed by bundled `ffmpeg` and
`ffprobe` command-line binaries invoked as subprocesses, rather than by linking the libav*
C libraries in-process. Every operation is therefore a reproducible command that can be run
and debugged directly in Terminal — decisive when building through an AI assistant as a
beginner.

## Consequences

- The app is distributed via Developer ID signing + notarization, **not** the Mac App Store,
  because executing bundled binaries from a sandboxed App Store app is impractical. HandBrake
  and LosslessCut distribute the same way.
- Sandboxing/App-Store packaging is explicitly out of scope for now; revisit only if needed.
