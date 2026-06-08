# Audio is always rebuilt, and conformed to the target clip's codec

vid_conform smart-renders **video** (stream-copy the untouched span, re-encode only the
boundary GOPs), but it does **not** smart-render audio. On every export the audio track is
fully rebuilt: each clip's audio is decoded over its exact kept range and concatenated at
the sample level into one continuous track, then re-encoded — by default to the **target
clip's** audio codec. There is no audio stream-copy path.

## Context: why audio is rebuilt rather than copied

A stream-copied audio cut can only land on an audio-packet boundary, which is not the video
cut point — leaving audio and video tens of milliseconds apart at every join (measured
~120 ms on real footage). Re-encoding the audio over the exact kept range, as one continuous
sample-level concat, removes per-join priming gaps and keeps audio aligned with the
frame-exact video cut (this is the audio half of the keyframe-aligned-cut work, ADR-0008).

So audio is *always* re-encoded, for every clip, regardless of whether the clip's video
matches the target. The only open question is **to which codec**.

## Decision: conform audio to the target clip's codec, fall back to AAC

The rebuilt audio is encoded to the **target clip's** audio codec by default. The target
clip already defines the project's output spec (ADR-0005); having the audio match it makes
the output a true instance of that spec, and — importantly — makes a vid_conform export
**round-trip**: re-importing an exported file matches the target instead of being flagged
for a needless re-render. (The earlier behaviour hard-coded AAC, so re-importing an export
of, say, an mp2 source was always badged "re-encode" purely on the audio codec.)

Sample rate and channel count are preserved from the source; they are not resampled. This is
safe because they remain **match criteria** (ADR-0005, updated): a clip is only smart-rendered
when its audio sample rate and channels already equal the target's, so the rebuilt tracks
share a format and the sample-level concat needs no resample step.

**Fallback.** Some codec/container combinations are awkward — verified in the shell, the only
real offender among the broadcast codecs is **mp2 in an MP4 container** (the MP4 muxer
relabels it mp3); TS and MKV carry mp2/aac/ac3/mp3 cleanly, and MP4 carries aac/ac3/mp3. When
the target codec cannot sit cleanly in the chosen container — or is an unknown/unmappable
codec — the export falls back to **AAC** and surfaces a warning, never producing a
mislabelled or unplayable file. AAC is the right fallback: it is audibly transparent at the
192 kbps used and is carried by every supported container.

## Consequences

- A vid_conform export round-trips: re-importing it is smart-renderable, not re-encoded.
- Audio codec is **removed from the match verdict** (ADR-0005): since audio is always rebuilt
  to the target codec, a clip's *source* audio codec never blocks its video from being
  smart-rendered. Sample rate and channels stay in the verdict.
- Audio is always lossy-re-encoded, even for a clip that already matches the target codec.
  This is inherent to the sample-accurate-join approach and accepted.
- Bitrate is a fixed 192 kbps and rate/channels follow the source. Making the audio export
  settings user-configurable (codec, bitrate, sample rate, channels) is deferred to a later
  feature (tracked as a GitHub issue).
