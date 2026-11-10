---
name: ci-local-before-remote-workflow
description: Mandatory workflow for CI fixes on this repo — verify green locally via ci-local.sh before every push to GitHub, never round-trip fixes through remote CI
metadata:
  type: project
---

When fixing a CI failure, or before any push that touches build/test/CI config, run `scripts/ci-local.sh` and
get it green BEFORE pushing. If remote CI still fails, go back to the script, fix, confirm green, then push again.
Never iterate by push-and-watch-GitHub-Actions: each attempt costs a CI round-trip instead of a local run.

**Why the Xcode must match the CI runner:** Swift strict-concurrency diagnostics and SDKs differ between Xcode
versions, so a green run on another Xcode proves nothing. The script fails hard when the exact Xcode is missing;
a silent skip once gave a false green. If the local Xcode changes, re-match `runs-on` in `ci.yml`.
Details: [[ci-local]] skill.
