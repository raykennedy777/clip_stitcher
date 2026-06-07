# Cut-editor preview uses FFmpeg-decoded source frames, not AVPlayer

The cut-editor previews video by having FFmpeg decode the exact source frame on demand and
rendering it into the view, rather than using AVFoundation/AVPlayer. Two facts force this:
the primary content is MPEG-2 / MPEG-TS, which AVFoundation cannot open at all; and the in/out
points selected in the preview drive the actual cut on the source file, so the preview must
show the *true source frame N* for cuts to be frame-accurate.

## Consequences

- v1 has no real-time synced-audio playback. The Play button steps frames best-effort
  (possibly below real time, no audio). Real-time streamed playback with audio is a deferred
  enhancement built on a long-lived decoder process.
