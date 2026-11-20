---
name: delete-comment
description: >-
  Audit code comments in clip_stitcher, classify each as Tautology, Stale, Excuse, or
  Decision Record, take the required action (delete, file a GitHub issue, or move to an
  ADR), and ratchet down .comment-ratchet.json.
---

# `/delete-comment`

Audit and eliminate code comments from this repository without losing genuine architectural
decisions or burying hacky implementations.

## Policy

Code comments (`//`, `///`, `/* ... */`) are banned in Swift source files (`Sources/`, `CLI/`,
`Tests/`) and enforced by `python3 scripts/lint-comments.py` against `.comment-ratchet.json`.
The sole exception is a bare ADR signpost (`// ADR-NNNN` or `// ADR-NNNN, ADR-MMMM`) pointing
to an existing file in `docs/adr/`, reserved for genuinely non-obvious invariants where a reader
could otherwise mistake load-bearing behavior for a bug. Every comment must be triaged before
deletion — never blindly strip comments without checking whether they hide a hack or document an
undocumented decision.

## Workflow

### 1. Pick the scope

- If the user named specific files or directories, audit those.
- Otherwise run `python3 scripts/lint-comments.py --stats` (or inspect `.comment-ratchet.json`)
  and pick the next highest-comment files to burn down.
- List exact comment blocks for a file with:
  ```sh
  python3 scripts/lint-comments.py --file <path>
  ```

### 2. Load context before classifying

Read:
- `CONTEXT.md` (canonical domain vocabulary — use these terms in issues and ADRs)
- Existing ADRs in `docs/adr/` (to avoid duplicating decisions already recorded)
- Open GitHub issues via `gh issue list --state open --limit 100` (to avoid filing duplicate issues)

### 3. Classify every comment block in context

Read the surrounding code for each comment block and assign exactly one category:

| Category | Definition | Action |
| --- | --- | --- |
| **Tautology** | Repeats what is already visible from the code, obvious docstrings, `// MARK:` dividers, or narration of the next line. | Delete the comment. |
| **Stale** | References outdated names, already-shipped future work, removed code, or behavior that no longer matches the implementation. | Delete the comment. |
| **Excuse** | Papers over or rationalizes a hacky implementation, tech debt, swallowed error, unsafe concurrency cheat, duplicated fragile logic, or shortcut in our own code. | Check open issues first; if untracked, file a GitHub issue (`gh issue create --label needs-triage`) describing the hack and desired fix, then delete the comment. |
| **Decision Record** | Documents a genuinely important, non-obvious engineering/architectural decision, invariant, or external platform/ffmpeg constraint. | Check `docs/adr/` and `CONTEXT.md`. If already covered, delete the comment. Otherwise move the decision into a new ADR (`docs/adr/NNNN-slug.md`) or update the relevant existing ADR, then delete the comment — optionally leaving a bare `// ADR-NNNN` signpost only if the line would otherwise look like a bug or trap. |

Distinguishing **Excuse** vs **Decision Record**:
- A deliberate, shell-de-risked architectural constraint forced by FFmpeg, container specs, or
  macOS/AppKit behavior is a **Decision Record**, not an Excuse.
- A shortcut or flaw in *our* code (e.g., an ad-hoc fallback, fragile string parsing, missing
  synchronization, duplicated logic, or "for now" workaround) is an **Excuse** — file an issue.

### 4. Delete comments cleanly

- Remove full-line comments and collapse any redundant blank lines left behind (avoid double blank
  lines or blank lines immediately after `{`).
- Strip trailing inline comments and any trailing whitespace before the newline.
- Never alter string literals (including URLs like `https://...`, raw strings, or multiline strings).
- Do not change code behavior during comment cleanup; fixes for Excuses happen in the tracked issues.

### 5. Ratchet the lint baseline and verify

```sh
python3 scripts/lint-comments.py --ratchet
python3 scripts/lint-comments.py
```

`--ratchet` strictly lowers `.comment-ratchet.json` (removing files that reach 0) and refuses any
increase.

Then build and test (following `docs/agents/engine-workflow.md`):

```sh
xcodebuild build -scheme clipstitch -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme ClipStitcher -destination 'platform=macOS' \
  ENABLE_DEBUG_DYLIB=NO ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -skip-testing:ClipStitcherTests/FieldCodedRepairIntegrationTests
```

### 6. Report

Summarize:
- Files audited and category counts (`Tautology`, `Stale`, `Excuse`, `Decision Record`)
- Links to every GitHub issue filed (for Excuses)
- Links to every ADR created or updated (for Decision Records)
- Exact lines of code shed and remaining `.comment-ratchet.json` total
