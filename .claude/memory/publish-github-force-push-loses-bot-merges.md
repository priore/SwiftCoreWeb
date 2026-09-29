---
name: publish-github-force-push-loses-bot-merges
description: scripts/publish-github.sh force-push overwrites any PR merged directly on GitHub (e.g. via dependabot-auto-merge.yml) that never made it into the internal repo
metadata:
  type: project
---

`scripts/publish-github.sh` force-pushes `master`/`develop` from the internal repo (source of
truth) to the GitHub mirror. [scripts/GITHUB-PUBLISHING.md](../../scripts/GITHUB-PUBLISHING.md)
documents this as intentional for bot commits like `cla.yml`'s `cla-signatures.json` — but it
silently applies to **any** merge that happened directly on GitHub and never round-tripped back
into the internal repo, including `.github/workflows/dependabot-auto-merge.yml` auto-merging a
patch/minor Dependabot PR straight into GitHub's `master`.

Concretely: Dependabot PR #3 (swift-syntax 509→604 bump) was auto-merged on GitHub on 2026-09-24,
but the bump was never present in the internal repo. The next `publish-github.sh` run overwrote
GitHub's `master` back to the old version, silently reverting the merge. Dependabot then reopened
the identical bump as PR #6 days later, which looked like a flaky/regressed bump but was actually
just the same already-approved change lost to the force-push.

**Why**: unlike `cla.yml`'s file (genuinely fine to lose/regenerate), a dependency bump is real
work that must survive. `GITHUB-PUBLISHING.md`'s bot-commit list doesn't call this out.

**How to apply**: before running `publish-github.sh`, check for PRs closed/merged directly on
GitHub since the last publish (`gh pr list --state merged --search "merged:>=<last-publish-date>"`)
whose branch commits aren't already in the internal repo's history — cherry-pick them into
`develop`/`master` internally first, or the merge is silently reverted on the next publish. See
[[ci-local-before-remote-workflow]] for the adjacent "verify before you push" habit.
