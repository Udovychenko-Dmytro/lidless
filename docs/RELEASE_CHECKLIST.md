# Release checklist

## v0.1.0 — 2026-08-11

- [x] Version is `0.1.0` and build number is `1`.
- [x] GPL-3.0-only and trademark notices are present in the repository and app.
- [x] Public fixtures contain synthetic identifiers.
- [x] Full automated suite: 913 passed, 0 failed.
- [x] ShellCheck completed with only the documented test-harness exclusions.
- [x] Both executables contain `arm64` and `x86_64` slices.
- [x] Strict code-signature verification passes.
- [x] Public snapshot and release archive pass the privacy scan.
- [x] Release ZIP checksum matches after extraction and verification.
- [ ] A new physical ON/OFF lid cycle was not performed during release preparation.

The physical cycle is intentionally unchecked: an already-running remote Lidless
session was preserved instead of changing persistent sleep state solely for a
release test. The current ON state and UI were previously verified live, and the
release uses the regression suite plus bundle-level validation.
