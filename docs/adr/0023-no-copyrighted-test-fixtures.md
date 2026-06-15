# Test fixtures carry no copyrighted media; integration tests build them from a private capture and skip when it's absent

This repo is intended to go public, and the real-world test material — the Polsat / MotoGP
broadcast captures the engine was de-risked against — is copyrighted. So **no copyrighted media
may be committed to the repo**, by any mechanism: not directly, and not via git-lfs (both
publish the bytes). An integration test that genuinely needs such a source instead **generates
its fixture on demand** — a fast `-c copy` slice of the private capture, written into a
fully-gitignored local fixtures folder — and **skips loudly** when neither the cached slice nor
the private capture is present (a fresh clone, another machine). The committed artifacts are the
test code and a documented capture path; never the video.

This is forced rather than chosen for the field-coded (PAFF) repair test (issue #61): the
encoders in this ffmpeg build are MBAFF-only — there is no way to synthesise a PAFF source — so
a real slice of the copyrighted capture is the *only* field-coded fixture obtainable, which is
exactly why it can't be committed. The same rule governs every future fixture of this kind.

## Considered options

- **Generate on demand, never commit (chosen).** Zero copyrighted bytes in history; runs for
  real wherever the private capture lives; skips loudly elsewhere. The only option compatible
  with a public repo.
- **Commit the slice / use git-lfs.** Rejected: both distribute the copyrighted content to the
  public, regardless of where git stores it.
- **Synthesise a fake fixture.** Not possible for PAFF (MBAFF-only encoders); a freely-licensed
  PAFF-and-damaged clip isn't reliably obtainable.

## Consequences

- **A green run can mean "skipped".** The skip must be loud (a clear reason in the output), so a
  skipped integration test is never mistaken for a passed one.
- **The gitignore is the safety rail.** The local fixtures folder ships a `.gitignore` of `*`
  plus `!.gitignore`, so any file in it — whatever its name — is unstageable; no copyrighted
  fixture can reach a commit even by accident.
- **These tests stay out of the fast unit suite.** They run real ffmpeg (seconds to minutes) and
  belong in their own suite so the everyday run stays fast; see the test-signing and
  headless-verification constraints already documented for this project.

## The field-coded repair test (issue #61), concretely

- **Suite:** `FieldCodedRepairIntegrationTests` (`Tests/FieldCodedRepairIntegrationTests.swift`).
  It skips loudly (`@Test(.enabled(if: PAFFFixture.available, "…"))`) when neither the cached
  slice nor the capture is present.
- **Fixtures folder:** `Tests/Fixtures/field-coded/`, located at runtime from `#filePath` (env
  and CWD don't reach the test runner). It ships only a `.gitignore` of `*` + `!.gitignore`; the
  cached `paff_slice.ts` and `paff_slice_repaired.ts` are unstageable.
- **Private capture (never committed):**
  `~/Desktop/working/motogp_2026/sunday/polsat_sport_premium_2_20260607_1842.ts`.
- **Slice recipe (cut on demand, cached):** a fast stream-copy window over the capture's first
  damage zone (~883 s) — field-coded **and** carrying a video damage zone:
  ```
  ffmpeg -v error -ss 850 -i <capture> -t 90 \
    -map 0:v:0 -map 0:a:0 -map 0:a:1 -c copy -y paff_slice.ts
  ```
- **Run commands** (the suite runs ~20–30 s — a full damage-to-EOF repair of the slice):
  - everyday fast run excludes it:
    `xcodebuild test … -skip-testing:VidConformTests/FieldCodedRepairIntegrationTests`
  - on demand / before a release:
    `xcodebuild test … -only-testing:VidConformTests/FieldCodedRepairIntegrationTests`
