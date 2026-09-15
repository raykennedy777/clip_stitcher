# clipstitch — speed and agent-usability review, 2026-09-15

Evidence: (a) timed re-run of the 8-clip round job (8 clips, 218 050 frames, 4.06 GB out), log `v9_timed.log`, process samples `v9_ps.log`;
(b) 2-clip control `ctl_2clip.log` (7000 frames, 01:08); (c) read-only code review of vid_conform HEAD 8bacae6; (d) transcript mining 2026-08-18..09-15 (`clipstitch_usage_report.md`).

## Where 15:36 of wall time went (v9 job)

| phase | time | detail |
|---|---|---|
| boundary x265 re-encode | 07:11 | 23 993 frames re-encoded on a "copy" job; two heads of 13 448 and 9 090 frames |
| verify decode of every finished piece | 06:16 | `ffmpeg -xerror -i c<i>_joined.mkv -f null` over the whole piece |
| Fill conform (6 534 frames, crf 21) | 01:34 | the only encode the job asked for |
| probe + index + damage scan (16 GB source) | 00:19 | not a cost |
| copies, concats, final mux, audio gate | ~00:30 | |

Method: process list sampled every 3 s, so each figure is ±3 s and sub-3 s copies were not caught. Rough cut keyframes are every 5 s (250 frames), but copy may start only at a leading-picture-free keyframe (ADR-0009); x265 default open-GOP makes most of them CRA, so a head edge re-encodes minutes.

## Ranked changes

Speed
1. Start copy spans at any keyframe by stripping the CRA's RASL packets (clip_stitcher #68, open). Removes most of the 07:11.
   Measured alternative on our side (gop1.log/gop0.log, 60 s clips, keyint 250, 2-clip job with mid-GOP in-points): open-gop=1 re-encoded 600+1500 frames, wall 43.7 s; open-gop=0 re-encoded 200+50+150+50 frames, wall 16.6 s; both 2100 frames exact. So `--no-open-gop` in encode_cfr.sh bounds every head edge to one GOP. Scope: rounds whose rough cut is the user's own x265 re-encode; slight compression cost. ROADMAP Milestone 2b names 'M2 CLI-only re-encode cost proves painful in practice' as its trigger — 07:11 on an 8-clip copy job is that evidence.
2. Bound the verify decode to the re-encoded spans plus a keyframe-anchored window across each seam (BoundaryReencodeEngine.swift:775, ConformEngine.swift:295). Removes most of the 06:16. Keep software decode (#113).
3. Parallelise independent clip pieces (ExportEngine.swift:1345) with a bound of 2.
4. `-preset faster` on boundary re-encodes after a quality check on the real HEVC capture.

Agent usability
1. `clipstitch --plan job.json` -> JSON: per clip copy/re-encode/conform + reason, segment ranges, copy-safe keyframes near each in/out, expected frame count, audio codec and bitrate out. ExportPlanner.copyShare already exists (GUI only). Nine renders at ~15 min each on that round; a 6:59 conform to learn a SAR mismatch (src/video/AGENTS.md:168).
2. Say what it does to audio, and let the job set it: re-encode halves bitrate (384->192; 5.1 = 32 kbps/ch, the user: "terrible", docs/2026-rounds.md:1322); #4 open. Print codec/bitrate in/out per track.
3. Finer, timestamped progress with stage names and the ffmpeg argv (`--log file`, JSON lines). Agents polled >=71 times in 3 sessions.
4. Name the clip and join in a decode refusal (rc 70 came with 3096 "could not find ref" lines and no location); one final verdict line that survives a pipe.
5. Frame-rate match by rational value, not string (MatchEvaluator.swift:60): a 50.0002 avg_frame_rate forces a full conform silently. Post-mux video gate (frame count, PTS) so the hard gate is the tool's own.

Already tracked: #68, #95 (plan visualisation, GUI), #99, #4. Fixed and no longer current: temp blow-up (25c54b9), duplicate PTS (65f2a67), fill audio early, CRF-28 heads (fc46da3), silent empty audio (c2e3ccb).

Footnote: single-pass assemble (concat list straight into the final mux) measured only ~00:09 of concat+mux here; not worth ranking.
