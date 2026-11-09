---
name: wiki-page-names-new-docs
description: every new/renamed/moved docs/*.md needs a PAGE_NAMES entry in scripts/wiki-flatten.py, otherwise the Wiki sync workflow fails after the push to master
metadata:
  type: project
---
`.github/workflows/wiki-sync.yml` runs `scripts/wiki-flatten.py` on every push to `master`. The script raises
`KeyError: '<path> has no entry in PAGE_NAMES'` for any `docs/` file missing from its `PAGE_NAMES` dict, so the
public Wiki stops updating (the push itself still succeeds, which hides the problem).

**Why:** `web/BLOB_DOWNLOADS.md` was added in 1.3.0 without an entry; the failure only showed after the 1.3.3
release and cost a second fix-and-publish round.

**How to apply:** in the same commit that adds, renames or moves a `docs/**/*.md`, add the `PAGE_NAMES` entry and
check locally with `python3 scripts/wiki-flatten.py docs "$(mktemp -d)"` (must exit 0). Related: [[ci-local-before-remote-workflow]].
