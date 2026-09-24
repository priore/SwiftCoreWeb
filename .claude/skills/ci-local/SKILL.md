---
name: ci-local
description: Run this repo's CI build-and-test steps locally, exactly as .github/workflows/ci.yml defines them, before pushing. Use whenever fixing a CI failure, before any push to GitHub, or when asked to "run CI locally" / "check CI passes".
---

# ci-local

Runs `.github/workflows/ci.yml`'s `build-and-test` job locally so fixes are verified before pushing, instead of round-tripping through GitHub Actions.

## Usage

```
scripts/ci-local.sh
```

Parses the `run:` commands straight out of `.github/workflows/ci.yml` (single source of truth — no drift between the script and the workflow) and runs them locally, with one adjustment: the simulator destination's `OS=` pin is dropped and resolved to whatever's actually installed on this Mac for the requested device name, since CI and a local machine rarely have the exact same simulator runtimes.

Exits non-zero on the first failing step, same as CI would.

## When the workflow changes

The script re-parses `ci.yml` on every run — no manual sync needed when steps are added/edited there. If a step needs different handling locally (e.g. another `-downloadPlatform` or Xcode-select step), edit `scripts/ci-local.sh`'s step handling, not this doc.

## Requires the exact Xcode version CI uses

The script fails hard (does not skip) if `ci.yml`'s `xcode-select` target Xcode isn't installed at that exact path. A pass on a different Xcode is not a CI pass — Swift's strict-concurrency diagnostics and SDKs differ between Xcode versions, so a green run on e.g. Xcode 27 does not prove Xcode 16.4 (what `macos-15` runners actually use) is green. Install the matching version (`xcodes install 16.4`, or Apple Developer downloads) before trusting this script's output.

## Workflow

1. Make the fix.
2. Run `scripts/ci-local.sh`.
3. Red → fix → re-run. Repeat until green.
4. Only then commit, merge to master, and publish (`scripts/publish-github.sh`).
