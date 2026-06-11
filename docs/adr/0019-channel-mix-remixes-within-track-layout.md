# Channel mix remixes within the output track's layout

A clip's channel mix (Original / Stereo / Left only / Right only / Mono) changes only what
is mixed *into* its output audio track, never the track's channel layout itself — picking
Mono on a clip does not produce a mono output track. Every clip on an output track is
joined into one continuous stream (ADR-0014), so the track can have exactly one layout
for the whole export; a per-clip layout change is structurally impossible, and an
export-wide layout setting was rejected as a different, coarser feature. Semantics are
defined relative to the source's normal stereo listening experience: Stereo is a deliberate
surround→stereo fold-down (no-op for mono/stereo sources), Left/Right only take one side
of that fold-down, Mono folds everything to one signal. Options that would be no-ops for a
given source are disabled in the UI, and a slot's mix resets to Original when its source
changes, since the choice is a judgment about that specific source's content. The same mix
applies on all three playback surfaces — export, cut-editor, output preview — via the
shared per-leg ffmpeg filter chain.
