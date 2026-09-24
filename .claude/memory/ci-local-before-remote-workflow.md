---
name: ci-local-before-remote-workflow
description: Mandatory workflow for CI fixes on this repo — verify green locally via ci-local.sh before every push to GitHub, never round-trip fixes through remote CI
metadata:
  type: project
---

When fixing a CI failure (or before any push that touches build/test/CI
config) on this repo: run `scripts/ci-local.sh` and get it green BEFORE
pushing to GitHub. If remote CI still fails after a push, go back to
`scripts/ci-local.sh`, fix there, confirm green, only then push again.
Never iterate fixes by push-and-watch-GitHub-Actions-fail — burns a CI
round-trip (minutes) per attempt instead of a local one (seconds-minutes).

**Why `ci-local.sh` must use the identical Xcode build as the CI runner**,
not just "some Xcode": Swift's strict-concurrency diagnostics and SDKs
differ between Xcode versions. A green run on a different Xcode proves
nothing about the actual CI runner. `scripts/ci-local.sh` fails hard (does
not silently fall back) if the exact Xcode version [.github/workflows/ci.yml](../../.github/workflows/ci.yml)'s
`runs-on`/`xcode-select` step requires isn't installed at that path — this
was a real bug once (silent skip gave a false green while testing Xcode 27
against what was then a `macos-15`/Xcode 16.4 CI target). See
[[../skills/ci-local/SKILL.md]].

Current setup: CI runs on the `xcode-27` runner label (Xcode 27.0 build
27A266a), chosen specifically because it matches the Xcode already
installed on this dev machine — so no separate Xcode install is needed to
get a trustworthy local pass. If the local Xcode version ever changes,
`ci.yml`'s `runs-on` needs to be re-matched too, or `ci-local.sh` will
correctly refuse to give a green.

Publish flow to GitHub (mirror, not the real remote — Gitea's `origin` is):
`scripts/publish-github.sh <github-url>` (force-pushes a filtered history,
strips internal-only paths). See [[publish-github-vs-local-gitea.md]] if
that memory exists, or `scripts/GITHUB-PUBLISHING.md`.
