# Multi-track audio: per-track rebuild with silence fill, sample-exact legs

Slice 9 generalises the audio rebuild (ADR-0010) from one hardcoded output track to N.
Sources can carry several audio tracks; the output carries **as many tracks as the
richest input** (clips with 1, 3 and 4 selected tracks → a 4-track output), with
**silence filling** track *t* wherever a clip has no track *t*. Each clip can re-point
any of its tracks at another stream of its own file or at an external audio file.

All recipes below were de-risked in the shell on real multi-track footage (a genuine
4-track MKV: mp2 mono + aac stereo ×2 + ac3 stereo, mixed language/title tags) joined
with the single-track test clips, in all three output containers (TS, MKV, MP4).

## Decision 1: one concat chain per output track, every leg forced to the exact kept duration

The rebuild becomes N independent filter chains — output track *t* concatenates, per
clip in timeline order, either the clip's selected source for track *t* or generated
silence:

- real leg: `[i:a:s]aresample=<rate>,aformat=channel_layouts=<layout>,atrim=end_sample=<N>,apad=whole_len=<N>`
- silence leg: `anullsrc=r=<rate>:cl=<layout>,atrim=end_sample=<N>`

where `N = round(keptDuration × rate)` is the clip's kept video duration in samples.
Then per-track `concat` → `-map [a0] -map [a1] …`.

**The `atrim`+`apad` exactness is load-bearing, not cosmetic.** Measured in the shell:
two tracks of the *same* clip decoded over the *same* 10-second window came back ±16
samples apart (10.000333 s vs 9.999667 s — audio-packet granularity differs per codec).
Without forcing every leg to the same sample count, the N output tracks drift apart at
every join. With it, every track's join lands on the identical sample position;
verified by per-half `volumedetect` (silence-filled halves measure at the encoder's
digital-silence floor, ≈ −91 dB) and sample counts in all three containers.

Relation to issue #3 (audio join offset): this slice does not change where audio starts
relative to video — #3's cause is untouched — but the exactness forcing now also applies
to the single-track case, so leg-length jitter no longer accumulates across joins.
Re-measure #3 after this lands.

## Decision 2: output track spec — count from the richest clip, format from the target first

- **Track count** = the maximum selected-track count across the clips.
- **Track *t*'s sample rate and channel layout** come from the **target clip's** track
  *t*; when the target has no track *t*, from the first clip in timeline order that
  does. Silence legs are generated in that format; every real leg is
  resampled/remixed to it by its chain.
- **Codec**: all output tracks use the **one** codec resolved exactly as today
  (target's audio codec, container-fallback to AAC — ADR-0010 unchanged). Per-track
  codecs (mp2 + aac + ac3 mixed in one file) were verified working in all three
  containers, so per-track codec choice stays open for the custom-audio-settings
  feature (issue #4), but is not exposed now.
- **Metadata**: language and title are written per track (`-metadata:s:a:t`) from the
  same precedence (target's track *t*, else first clip carrying it). Container
  reality, verified: **MKV keeps language + title; TS and MP4 keep language only** —
  titles do not survive outside Matroska, and that is the muxer's behaviour, not a bug.

## Decision 3: audio drops out of the smart-render verdict

ADR-0010 kept sample rate + channels as match criteria because the single-track concat
referenced matching legs unfiltered. Decision 1 puts `aresample`+`aformat` on **every**
leg regardless, so a rate/channel mismatch can no longer break the concat — and
therefore no longer needs to force a video re-encode. MatchEvaluator's audio comparison
is removed entirely: **a clip's audio never blocks its video from smart-rendering.**
(The per-leg `audioConform` special case dissolves into the uniform chain.) Audio-only
projects (issue #1) and custom audio settings (issue #4) both get simpler under this
rule.

## Decision 4: external audio files are positioned like internal streams

A track re-pointed at an external audio file aligns **file start = video-file start**:
the external file behaves exactly as if it were another audio stream inside the clip's
own container, and the clip's in/out window cuts the same span out of it. (Confirmed
with the user, 2026-06-10.) The same leg chain handles it — `aresample` absorbs a
44.1 kHz file in a 48 kHz project; `apad` silence-fills when the file ends before the
clip's out point; `atrim` discards what runs past it. Verified in the shell with a
44.1 kHz MP3 shorter than the clip.

**Length-mismatch rule** (the roadmap's open question, answered by the user,
2026-06-10): always pad/trim as above; show a notice on the clip when the external
file's length differs from the clip's video by **1 second or more**; stay silent under
that. Never an error.

## Per-clip track selection

Each clip carries an ordered list of selected audio sources (a stream of its own file,
**any chosen audio stream of an external file** — which may itself be another video with
several tracks — or none). An external file is probed when picked, so its streams are
selectable by name like the clip's own. The cut-editor names tracks from container
metadata — "`title` (`language`)" when present, falling back to "Track N" — with the
caveat above that titles generally only exist on MKV sources.

## Consequences

- The project JSON gains the per-clip track list; old saves decode as "track 1 of own
  file" (optionals with defaults), staying backward-compatible.
- An export's track count can change just by adding a richer clip; silence on the
  extra tracks is by design and costs almost nothing (anullsrc encodes at the floor).
- MatchEvaluator loses its audio dimensions (Decision 3) — ADR-0005's strict matching
  now reads on video alone.
- Output naming fidelity is container-bound: full track names round-trip only via MKV.
- De-risk fixture gotcha worth keeping: a naive `-c copy` cut of an **open-GOP HEVC**
  source makes a video piece whose head packets carry unknown timestamps and abort the
  MKV mux ("Can't write packet with unknown timestamp"). Test carrier pieces must be
  cut at leading-picture-free keyframes (as the real engine does) or re-encoded.
