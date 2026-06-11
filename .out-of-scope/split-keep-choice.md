# Confirm-time keep choice for split ranges

vid_conform does not offer a TMPGEnc-style choice at cut-editor confirm time of
which split ranges to register as clips ("keep both sets" vs "keep only the
alternating set").

## Why this is out of scope

The split slice deliberately shipped with the simpler two-step flow: every split
range becomes a clip, and unwanted ones are deleted in the Source view
(multi-select batch delete, issue #12). Issue #22 was filed as a placeholder in
case that flow proved annoying in real-world ad-cutting use.

It didn't. During triage on 2026-06-11 the maintainer reported having used the
split feature for real and finding the delete-the-leftovers step fine as is. A
confirm-time dialog, per-range keep/discard toggles, or a preference would each
add UI surface and a decision point to every split confirm in exchange for
removing a step the maintainer doesn't mind.

The clip-replacement data model (ADR-0017) was never in question — any of the
proposed shapes were confirm-time behavior only — so nothing architectural
blocks revisiting this if heavy commercial-cutting use someday makes the
two-step flow grate.

## Prior requests

- #22 — "Cut editor: confirm-time keep choice for split ranges (TMPGEnc both/alternating)"
