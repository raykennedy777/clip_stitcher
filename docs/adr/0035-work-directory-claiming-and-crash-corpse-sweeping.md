# Work-directory claiming and startup crash-corpse sweeping

Normal exports clean up their temporary work directories in `defer`, but hard kills (force-quit,
`SIGKILL`, `^C`/`SIGTERM` on `clipstitch`, power loss) bypass `defer` and leave tens of GB of
abandoned temp directories on disk (issue #109). Because concurrent GUI and CLI exports are
normal — and a long render can run for hours — an age-only sweep cannot distinguish a live
export from a crash corpse without risking deleting an active render's pieces.

## Decision

**Every export claims its temp work directory immediately after creation with an atomic owner
PID marker, and both the GUI app and `clipstitch` sweep abandoned directories at startup.**

- **Claim marker:** Immediately after `createDirectory` (before any piece is written),
  `WorkDirectorySweeper.claim(_:)` atomically writes `.clipstitcher-owner.json` containing the
  owning process's PID.
- **Sweep verdict matrix:**
  - Marker present with a **live** PID → **keep** regardless of age.
  - Marker present with a **dead** PID → **delete** immediately.
  - Marker missing, empty, torn, or unparseable → classified `.unknown` (never `.dead`) and
    deleted **only** when untouched for `> 24 h`, keeping the microsecond window between
    `createDirectory` and `claim` safe against concurrent launches.
  - Any ambiguity resolves to **keep**; PID reuse fails safe (defers reclaim rather than
    risking data loss).
- **POSIX liveness check safety:** Liveness uses `kill(pid, 0)`, treating `EPERM` as alive.
  Non-positive PIDs (`pid <= 0`) are rejected before calling `kill` so a corrupt marker can
  never signal the process group (`0`) or all processes (`-1`).
- **Scope & filesystem safety:** Only real directories matching `clipstitcher-export-` or
  `clipstitcher-stitchjob-` are eligible (`clipstitcher-doctor-` directories are unclaimed and
  deliberately out of scope). Regular files and symlinks are skipped and never followed.
- **Execution timing:**
  - **GUI (`ClipStitcherApp`):** Runs in a detached `.background` task at launch — best-effort,
    never blocking startup even when unlinking tens of GB.
  - **CLI (`clipstitch`):** Runs synchronously at the start of `.stitch` (the CLI is
    short-lived and `exit()` would cut off a detached task), logs rather than printing to
    stderr so stderr remains the job's own output, and is skipped on `--plan` (a read-only
    query never unlinks anything).
  - Sweeping is strictly best-effort and can never fail an app launch or CLI run.

## Consequences

- Crash-abandoned export directories from either GUI or CLI runs are reclaimed automatically on
  the next launch without interfering with concurrent live renders.
- `clipstitcher-doctor-*` temp directories remain outside this sweeper's scope.
