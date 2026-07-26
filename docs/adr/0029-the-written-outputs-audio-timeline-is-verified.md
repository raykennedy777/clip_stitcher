# The written output's audio timeline is verified against the plan

Every video piece is verified before it ships — frame count against the plan, a decode pass,
and a timestamp self-check (ADR-0008, ADR-0009). The **final mux** then wrote the destination
and the export reported success, and nothing looked at the file that had been written.

That is how ADR-0028's defect escaped: ffmpeg exited 0 with an empty stderr, the video was
frame-exact, every audio sample was present, and the audio timeline had silently collapsed
onto a single timestamp partway through (issue #111). It was caught downstream, by a reporter
who treats an inconclusive correlation probe as a failure. A non-zero exit is trivially
handled by a caller; a silently truncated file is not.

ADR-0028 fixes one cause. It does not prove no other path can produce a short or
non-advancing audio track — and what emptied the leg in the reporter's original failing job is
**still unidentified**. So the class needs a gate, not only a fix (issue #112).

## Decision

**After the destination is written — connect mode's single file, each file in separate mode —
the export measures the audio it just produced and refuses the export when it disagrees with
the plan.** Two independent checks, because #111 showed the samples can all be present while
the timeline is broken:

1. **The timeline advances.** No audio track may carry a packet whose timestamp repeats or
   goes backwards.
2. **The extent matches the plan.** Each track's measured length must land within tolerance of
   the clips' combined kept duration — the same `totalSpan` the mux already derives for its
   progress fraction, and each clip's own kept duration in separate mode.

Both are needed because the containers disagree about what a collapse looks like: **MKV and TS
show the duplicate timestamps outright, MP4 masks them entirely** (its muxer bumps duplicates
apart, so check 1 finds nothing there — only the 2.016 s extent of a planned 7 s gives it
away).

Two more refusals fall out of the same measurement and are part of the gate: a track carrying
**no timestamped audio at all** (the extreme of check 1, and the one case an unknown planned
span must not excuse), and a file carrying **fewer tracks than the mux wrote** — a track that
isn't there has no timeline for either check to look at, which is precisely the silent
shipping this exists to stop. Measured on two-track outputs in all three containers: each
written track reports its own packets exactly once (a TS program's streams are double-counted
in `-show_streams`, but not in a packet dump).

A failure raises `ExportError.verificationFailed` naming the track, and where the timeline
froze or what it measured against what was planned; the CLI's existing mapping makes that exit
70. The gate **discards the file** it rejected: a failed verification must not leave a
passing-looking file at the destination. In separate mode that is per file — the files that
already finished are valid exports and stay, exactly as they do on a cancel (issue #32).

Facts and policy are split. `MediaProbe.audioTimelines` reports per-track facts (packet
counts, first/last timed packet, first non-advancing packet);
`ExportEngine.audioTimelineDefect` is the pure verdict over them, so the tolerance reasoning
is unit-tested against measured numbers rather than against a live ffmpeg run.

### Measured, not read from the container

The extent is measured **first timed packet to last, plus one packet interval**, and the
interval is the track's own mean:

- Not the container's declared duration: on the collapsed render it read 2.03 s of a file
  holding 8 s of samples.
- Not an absolute timestamp: the mpegts muxer starts its timeline at its own clock base
  (measured 1.43 s on a render of a 7 s plan), which says nothing about how much audio a
  track holds.
- Not a sample count: the sample count was *already right* on the broken render.
- The interval is read off the track because it differs per codec — 1024 samples for aac,
  1152 for mp2/mp3, 1536 for ac3 — and it is both the tolerance's unit and the length the
  last packet's own frame adds.

### The tolerance is three audio frames

Each of the three is a named, unavoidable term rather than a number tuned until the fixtures
passed:

1. the encoder's **priming** frame, which sits before zero — the deliberate ~10–21 ms
   audio-ahead compensation, not a sync defect;
2. the plan's final partial frame, which the encoder must **pad** to a whole one;
3. the container's rounding of the **last packet's slot**.

Each term is also structurally bounded by one frame, so three is a *ceiling* on what correct
output can differ by rather than the top of a measured range. It is applied in both directions:
only a shortfall is the reported defect, but a track longer than the clips it was built from is
the same disagreement with the plan, and the overshoot terms are what bound the allowance
anyway.

The unit is the track's **own** mean packet interval, not a fixed constant, so it adapts to the
codec's frame size and to a container that packs several frames per packet. The trade-off is
deliberate: a defect that *stretched* a track's spacing would widen its own allowance, but a
widened allowance is still orders of magnitude short of a collapse, whereas a fixed unit would
false-fail correct output whose packets are legitimately larger — and false-failing correct
output is the mistake this project has already paid for once.

Check 1 asks only that timestamps *advance*, never that they are evenly spaced — which is what
keeps it safe on a faithful copy of a legitimately irregular broadcast source. ADR-0008's
timestamp gate had to be taught that lesson the hard way (issue #19: it rejected correct
exports of a capture with ~714 real timestamp anomalies in 67 minutes), and this gate must not
repeat it.

When any clip lacks a kept duration there is no expected extent; check 2 then **skips rather
than guessing**, while check 1 still applies. `videoOnly` exports have no rebuilt audio and
skip the gate entirely; `audioOnly` exports are checked like any other.

## Evidence

De-risked in the shell before any Swift changed, replicating the real mux recipe:
MPEG-2/H.264/HEVC video in `.mkv`, `.mp4` and `.ts`, each of the four audio encoders the
policy can pick (aac/mp2/ac3/libmp3lame), audio-only outputs, a **real broadcast MPEG-2
capture** with irregular timestamps and a non-zero container start, a **real 4.5 h HEVC
capture** at deep windows, and single-frame keeps.

| | clean renders | the #111 collapse |
|---|---|---|
| extent vs plan | **+0.00 … +1.88 frames, never short** | **−717 … −819 frames** |
| non-advancing packets | 0 everywhere | 235/330 (MKV), 42/292 (TS), **0 (MP4)** |

So the allowance keeps ~1 frame of headroom over anything correct and stays two orders of
magnitude below the defect it separates. The error does not grow with length — the legs are
sample-exact by construction (ADR-0028), so the 4.5 h capture's render measured the same
fraction of a frame off as the 7 s one — which is why the tolerance is a fixed frame count and
not a proportion.

`OutputAudioGateTests` pins every one of those measurements as a case that must pass or fail.
`OutputAudioGateIntegrationTests` drives the gate against a **real broken file** — built with
the pre-#111 force, so it is the shipped defect rather than an imitation — and runs the real
export across all three formats × all three containers to prove correct output still passes.
Verified by mutation: cutting the tolerance to ~0 fails every clean export *through
`ExportEngine.export`*, which is what proves the gate is wired into the export and not only
into its tests.

## Consequences

- Every export with audio pays one extra demux-only pass over the finished file (no decode).
  In line with the per-piece verification the video path already pays, but not free on a
  multi-hour render, and it lands after the progress bar has reached the end of the mux phase.
- The read is per-packet over a whole file — millions of rows on a long multi-track render —
  so it streams through `ProcessRunner`'s live stdout reader into an incremental parse
  (issue #84's shape). Neither captured in memory nor spooled to a temp file: a captured
  per-packet dump deadlocks against the ~64 KB pipe buffer (measured: 10 minutes at 0 % CPU).
- The gate refuses; it does not recover. Repairing or retrying a failed export is out of
  scope, as is any packet-count gating of copy-cut video pieces (issue #99).
- A cause of a broken audio timeline that this gate catches is still a bug to find. The gate
  makes the class loud, not absent.
- The "a real broadcast MPEG-2 capture still passes" claim rests on shell measurement recorded
  as test cases, not on a test that reads such a capture: no copyrighted media may be committed
  (ADR-0023) and a synthetic source can't reproduce a broadcaster's timestamp irregularity. The
  exposure is small — the audio is *rebuilt*, never copied, so a source's irregular timestamps
  reach the output only through the decode, which the length force normalises.
