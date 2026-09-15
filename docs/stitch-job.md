# Stitch Job — the `clipstitch` CLI contract

A **Stitch Job** is a JSON file describing one stitch: which clips, in what order,
cut where, carrying which audio, conformed to which target, written to which kind of
output. It is the public contract between the `clipstitch` CLI and anything that
drives it (scripts, agents, other repos' pipelines). The shape deliberately mirrors
the app's Codable project model (`VidProject` / `Clip` / `OutputSettings`), and the
CLI runs the exact planning and export engine the GUI runs (ADR-0025) — a job is a
project the way a script would write one.

```
clipstitch [--verbose] <job.json> <output-file>
```

The CLI is headless and non-interactive: sources are plain file paths (no
security-scoped bookmarks), all human-readable output goes to stderr, stdout stays
silent, and the exit code plus the output file are the whole scriptable surface. An
existing file at `<output-file>` is overwritten. ffmpeg/ffprobe must be installed
(Homebrew or system paths) unless bundled.

## Example

```json
{
  "version": 1,
  "clips": [
    { "path": "/media/main.mkv",  "inFrame": 0,    "outFrame": 44161,
      "audioTracks": [0], "target": true },
    { "path": "/media/fill.mkv",  "inFrame": 51000, "outFrame": 51749,
      "name": "Fill 1", "audioTracks": [1] },
    { "path": "/media/main.mkv",  "inFrame": 44162, "outFrame": 100931,
      "audioTracks": [0] }
  ],
  "output": { "container": "mkv", "type": "videoAndAudio" }
}
```

Clips are stitched in array order into one output file. The same source file may
appear in any number of clips (it is probed and indexed once).

## Fields

### Top level

| field     | type   | required | meaning |
|-----------|--------|----------|---------|
| `version` | int    | yes      | Contract version. This build understands `1`; other values are refused. |
| `clips`   | array  | yes      | The timeline, in output order. At least one entry. |
| `output`  | object | no       | Output settings; every field optional (defaults below). |

### `clips[]`

| field         | type   | required | meaning |
|---------------|--------|----------|---------|
| `path`        | string | yes      | Plain path to the source file (`~` is expanded). Must exist. |
| `name`        | string | no       | Display name used in warnings/errors. Defaults to the file name. |
| `inFrame`     | int    | no       | First kept frame, 0-based, **presentation order** (the app's frame numbering, ADR-0006). Omitted = the clip start. |
| `outFrame`    | int    | no       | Last kept frame, **inclusive**. Omitted = the clip end. `inFrame == outFrame` keeps one frame. |
| `audioTracks` | [int]  | no       | Which of this file's own audio streams feed the output tracks, in output-track order — 0-based indices **among the file's audio streams** (`0:a:N`). Omitted = all of the clip's own streams in container order. Different clips may select different streams; that is how one output track changes source at a join. |
| `target`      | bool   | no       | Marks the target clip. Exactly one entry must set `true`. |

The **target clip** defines the output spec (ADR-0005): clips whose video properties
match it are smart-rendered — stream-copied outside join-boundary GOPs, with only the
partial GOPs at cut points re-encoded (ADR-0009) — and clips that don't match are
conformed, a full re-encode of their kept range to the target's spec (ADR-0011).
Audio is always rebuilt sample-aligned to each clip's kept video span (ADR-0014).

Frame numbers are frame-index positions, the same numbers the app's cut editor
shows. On a field-coded (PAFF) source the index counts *fields* (two per displayed
frame), exactly as in the app; such clips must also sit on copy-safe boundaries
(ADR-0024) — the export refuses otherwise.

### `output`

| field        | type   | default          | values |
|--------------|--------|------------------|--------|
| `container`  | string | `"mkv"`          | `"mkv"`, `"ts"`, `"mp4"` |
| `type`       | string | `"videoAndAudio"`| `"videoAndAudio"`, `"videoOnly"`, `"audioOnly"` |
| `conformCrf` | int    | encoder default  | 0–51 (lower = higher quality) |

Strings must match exactly (a typo'd `"MKV"` is refused, never silently defaulted).

`conformCrf` sets the CRF that **conformed** (non-matching) clips encode at — how a
fill clip's re-encode is pinned to the quality class of the footage around it.
Omitted, the conform runs at the encoder's own default (libx264 CRF 23, libx265
CRF 28). It applies to the x264/x265 conform encoders only (an MPEG-2 target has no
CRF and ignores it) and never touches smart-rendered clips — their boundary
re-encodes stay matched to the source as before.
There is no `mode` field: the CLI always connects the clips into the one output file
it was given; per-clip separate export stays a GUI affordance. For video outputs the
`<output-file>` extension must match the container (ffmpeg picks the final muxer
from the file name); audio-only outputs may use any name.

The rebuilt audio encodes to the target clip's audio codec where the container
allows it, else AAC with a warning (ADR-0010). Output track count and formats follow
the richest clip's selection, target-first (ADR-0014); a clip selecting fewer tracks
contributes silence to the ones it lacks.

## Validation

Structural checks (before any tool runs): known `version`, non-empty `clips`,
exactly one `target`, non-negative frame numbers with `inFrame ≤ outFrame`,
non-negative audio stream indices, known `output` strings, sources present on disk.

Post-probe checks (against the real file): frame numbers must be `< frameCount`,
and every selected audio stream must exist. The CLI **refuses** mismatches rather
than adapting (the GUI's reset-to-whole-clip and silence-fill reconciliations exist
for interactive edits, not for a script that asked for exact coordinates).

## Exit codes

Sysexits-flavored, so a driving script can tell whose fault a failure is:

| code | class | meaning |
|------|-------|---------|
| `0`  | success | The output file was written and verified. |
| `64` | usage | Bad arguments, or the output file's extension doesn't match the job's container. |
| `65` | invalid job | Unreadable/malformed job file, structural validation failure, a named source missing on disk, or a job/source mismatch (frame or audio index out of range). |
| `66` | probe/index failure | A source exists but couldn't be probed or frame-indexed (unreadable/corrupt media, no video track, ffmpeg/ffprobe not found). |
| `70` | export failure | Planning or producing the output failed (invalid plan, cut/conform/concat/mux error, output verification failure). |

Warnings (repair reports, conform color assumptions, codec fallbacks — the same
notices the app shows after an export) go to stderr prefixed `warning:` and do not
affect the exit code. Progress prints to stderr as `progress: N%` lines in 10 %
steps.

## The verdict line

The **last** stderr line of every run is one line that gives the outcome, so
`tail -1` of a piped log is the answer. A success ends with the output path:

```
Done: /media/out/stitched.mkv
```

A failure ends with the exit code, its class, and where the failure happened:

```
clipstitch: FAILED (70 export failure): clip 3 “part 4” — piece c3_joined.mkv — plan: reEncode [1234,14682) · copy [14682,56790)
```

The verdict never wraps a newline, and for a verification refusal it repeats that
refusal's own first line — the **location line**, which every verification refusal
opens with. The location line names:

- the clip's number, which is its **0-based index in `clips[]`**, and its `name`
  when the job gives one;
- the piece file the gate refused, whose `c<index>_` prefix is that same clip
  number;
- the segment plan that produced it (`reEncode`/`copy`/`repair` with each
  segment's half-open frame range), or `conform` for a conformed clip. A plan
  longer than four segments counts the rest as `· +N more`.

Above the verdict, a failure's detail is printed **bounded**: the first 5 lines, a
`… N more lines …` marker, and the last 10 lines. A decode refusal can carry
thousands of near-identical decoder lines, and the ones that matter are at the two
ends. `--verbose` prints the detail whole (stderr only — stdout stays silent).
