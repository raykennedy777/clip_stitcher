# clip_stitcher

A macOS app for frame-accurate video joining via smart rendering — re-encoding only the
frames at edit/join boundaries while stream-copying everything untouched. See `README.md`
for the goal, approach, and references.

## Engine workflow

De-risk every ffmpeg command in the shell — on all three formats and **in the actual output container** — before wiring it into Swift; force-kill the app before relaunching. See `docs/agents/engine-workflow.md`.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `raykennedy777/clip_stitcher` via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical triage roles map 1:1 to default label strings (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### UI automation

Accessibility identifiers and AX probing for driving the running app. See `docs/agents/ui-automation.md`.

### Code comments

Code comments (`//`, `///`, `/* ... */`) are banned in Swift files (`Sources/`, `CLI/`, `Tests/`), enforced by `python3 scripts/lint-comments.py` with a downward-only ratchet in `.comment-ratchet.json`. The sole allowed exception is a bare ADR signpost (`// ADR-NNNN` or `// ADR-NNNN, ADR-MMMM`) whose referenced ADR exists in `docs/adr/`, reserved for genuinely non-obvious invariants. Put engineering decisions in `docs/adr/` (or `CONTEXT.md`) and track workarounds/shortcuts as GitHub issues instead of excusing them inline. Use the `/delete-comment` skill (`.agents/skills/delete-comment/SKILL.md`) to audit and burn down any remaining baseline entries.
