# Every audio leg is backed by silence, so an empty leg can't stop the timeline

The audio rebuild builds one leg per clip per output track, conforms each to the track's
rate/layout, and forces it to the clip's exact kept duration in samples before joining the
legs with the `concat` filter (ADR-0014). The force was
`atrim=end_sample=N,apad=whole_len=N`: trim the overshoot, pad the shortfall.

That force needs the leg to be a stream. Reported from the `motogp_muxing` side (issue #111)
as "audio stops early", it fails when a leg's window decodes to **zero frames** — a track
whose audio ends before its video, a window past the audio end, a decode that yields
nothing.

## What the failure actually is

Not truncation. Measured in the shell on a source whose audio ends at 4 s while its video
runs to 12 s, three clips with the middle one's window past the audio end:

| | healthy | one empty leg |
|---|---|---|
| decoded samples | 336 896 | **336 896 — every sample present** |
| last audio packet pts | 6.997 s | **1.984 s** |
| non-monotonic packets | 0 of 330 | **235 of 330** |
| container duration (MKV) | 7.021 s | **2.026 s** |
| ffmpeg exit / stderr | 0 / empty | **0 / empty** |

The padding still writes its samples; what stops is the **timeline**. Every packet from that
join onward carries one identical pts, so a probe seeking past the collapse extracts nothing
(the reporter saw correlation confidence of exactly 0.000), the container declares a short
duration, and the clips after the empty leg are unplayable in place. Nothing else shows it:
the video stays frame-exact, sample count is right, and ffmpeg is silent and successful. Same
duplicate-timestamp family as ADR-0026, on the audio side.

The MP4 muxer *masks* the duplicates — it bumps them apart, so a packet-monotonicity check
passes there — but the declared duration is still short (2.01 s of a planned 8 s). Judging
audio extent by container duration alone, or by monotonicity in MP4 alone, misses this.

## Decision

**Concatenate an endless silence source behind every real leg, then cut the pair to the kept
length:**

- real leg: `[i:a:s]<mix,>aresample=<rate>…,aformat=…[Lsrc]`,
  `anullsrc=r=<rate>:cl=<layout>[Lpad]`,
  `[Lsrc][Lpad]concat=n=2:v=0:a=1,atrim=end_sample=<N>[L]`
- silence leg (a track this clip has no source for): `anullsrc=…,atrim=end_sample=<N>[L]`,
  unchanged

`apad` is gone: the backing covers the shortfall and the empty leg in one mechanism, and the
`atrim` alone decides the length. The silence source is deliberately **endless** — the
`atrim` downstream sets the extent, so no leg's length is computed in two places; `atrim`'s
EOF propagates upstream, so the run still stops when its work is done.

A leg of **unknown** kept duration stays unforced, exactly as before: with no length to cut
to, there is nothing to back it with either. Such a leg contributes its own natural length,
which can shift the clips after it, but never collapses the timeline. Where that leg would be
*silence*, the export refuses instead (`ExportEngine.assertAudioLegLengthsKnown`,
`ExportError.unknownSilenceLength`) — silence must be generated to some length, and zero
samples is the one length that breaks the join. The planner always stamps a positive kept
duration (`ExportPlanner.planItem` → `ExportEngine.keptWindow`, issue #75), so this is an
invariant guard, and a sub-sample duration rounds **up** to one sample rather than down to
none.

## Evidence

De-risked in the shell before any Swift changed, on MPEG-2/mp2, H.264/AAC and HEVC/mp2
sources, into `.mkv`, `.mp4` and `.ts`:

- **Healthy legs are bit-identical** to the old force — same decoded-PCM md5 and the same
  192 000 samples for a `48000 + 96000 + 48000` join, on all three formats. Comparison is on
  decoded PCM, never on two AAC encodes (those differ spuriously).
- **The empty leg is repaired** in every source × container combination: 0 non-monotonic
  packets, last pts within one audio frame of the planned span, declared duration matching,
  and the empty leg's span measuring digital silence of exactly its clip's length with the
  following clip's content byte-identical to its own solo render — the clips after the hole
  are not pulled earlier.
- **Scale and termination:** 17 clips × 4 tracks — 68 legs, so 68 silence sources in one
  graph — ran in the same 0.42 s wall time and 51 MB peak RSS as the old graph, with
  identical per-track sample counts.

`EmptyAudioLegIntegrationTests` is the regression net. It synthesises its own short-audio
sources with `lavfi` (ADR-0023), runs the empty-leg join in **all three containers** — MP4
masks the duplicate timestamps, so a single-container net would be blind there — and asserts
the timeline, not the sample count, because sample count is right in both the healthy and
the broken render. Verified by mutation: restoring the `apad` force fails the connect case
(235 of 330 packets sharing one pts) and leaves the healthy cases green.

## Consequences

- ADR-0014's Decision 1 leg recipe is superseded by the shape above; its exactness rationale
  (tracks of one clip decode ±16 samples apart, so every leg is forced) stands unchanged.
- Three filter chains per real leg instead of one. The graph is longer to read; the argument
  tests pin it exactly, and the runtime cost measured zero.
- An external audio file shorter than its clip is still padded — by the backing now rather
  than by `apad` (ADR-0014 Decision 4's length-mismatch rule is unaffected).
- What *emptied* a leg in the reporter's job is still unidentified; their copy source's audio
  is gapless. This makes an empty leg harmless whatever the cause. The post-mux gate that
  would make this class of defect fail loudly rather than ship is issue #112.
