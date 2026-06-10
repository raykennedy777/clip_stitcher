# Output preview audio: one monitored output track, restart-per-leg stitching

The output preview (sidebar "Preview") now plays audio with the assembled timeline
(issue #8): **one output track at a time**, chosen by a picker named like the
cut-editor's dropdown and **persisted per project** (`VidProject.monitoredOutputTrack`;
older saves decode to the default, track 1). What plays is exactly the export's track
*t*, leg for leg: `PreviewAudioPlan` resolves each (output track × timeline segment)
the same way the export's audio rebuild does (ADR-0014) — the clip's slot-*t* source
(own stream or an external file's chosen stream), or **real silence** through
silence-filled spans, with the playhead still moving. The streaming/clock foundation
is ADR-0015's `AudioStreamPlayer`, adopted unchanged in its hygiene (PCM subprocess,
counter-not-semaphore backpressure, audio as the master clock).

## The legs (all recipes de-risked in the shell on the three formats + the 4-track MKV, 2026-06)

- **Real leg**: the ADR-0015 PCM decode plus two additions — an `-af` per-leg conform
  to the *output track's* rate/layout (the same `aresample`+`aformat` the export puts
  on every leg of that track's chain, so the preview sounds like the export) and an
  input `-t` cap of the leg's remaining output duration. Byte counts came back exact
  on all formats (AAC legs run 32–96 samples short under input `-t` — ADR-0014's
  packet-granularity jitter; the node's trailing silence covers it), and the filter
  adds nothing to spawn latency (13–23 ms to first byte, same as ADR-0015's baseline).
- **Silence leg** (a track slot with no source): `anullsrc` through the same engine
  conform, capped by `-t` — verified byte-for-byte zero. The clock genuinely runs, so
  a silence-filled span needs no special pacing path: every leg, sounding or silent,
  is one ffmpeg spawn.
- Seek math is per leg: `segment.windowStart − that clip's container start_time`
  (the ADR-0013/0015 trap, probed per clip at preview load) plus the time already
  elapsed inside the leg. External files take the same value with no probing of
  their own (ADR-0015's measurement).

## Stitching at joins: restart-per-leg

When the audio clock crosses a join, the old leg's process is killed and the next
leg's is spawned at its start — the issue's "clean restart" floor, not the gapless
pre-spawn upgrade. Why this is safe and how it sounds:

- The `-t` cap means a restart that runs late can never leak audio from past the old
  clip's out point — the node renders silence from the leg's exact end until the new
  leg's first samples arrive.
- The gap is the spawn latency, 13–23 ms measured — under one frame period at 25 fps.
  The video waits on the new clock (the prime-deadline path), so A/V sync is
  preserved across the join; the seam is a possible brief silence, not an offset.
- **Whether that seam is audible on real footage is a human check** (#5: the GUI —
  and all listening — is not agent-drivable). If it bothers, gapless pre-spawn of the
  next leg is the recorded upgrade path; the plan/leg structure already isolates it.

## The clock

The preview's clock counts **output-timeline seconds**, uniform at the target rate,
so frame ↔ time is plain arithmetic (`frame / fps`) — no per-clip pts lookup like the
cut-editor's, because the output timeline is the conform's uniform grid by
construction (ADR-0012). The base re-zeros at every leg restart, mid-play track
switch, and play start (ADR-0015's restart pattern). Scrubbing/stepping stays silent
and pauses playback, as before. With no output tracks at all, playback falls back to
the old sleep pacing.

## Consequences

- The preview degrades to silence where the export would error (a missing external
  file): best-effort playback must not block the scrub.
- A mid-play track switch restarts the stream at the playhead — the cut-editor's
  monitor-switch semantics, per the pinned #8 decisions.
- The frame-quantized leg boundaries (`outputCount / fps`) differ from the export's
  sample-exact `atrim`+`apad` legs by under one frame at each join — inaudible for a
  preview, and exactness stays the export's job.
- "Monitored track" is still not glossarized in `CONTEXT.md` — flagged for the next
  `/grill-with-docs`.
