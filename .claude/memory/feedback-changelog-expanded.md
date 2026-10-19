---
name: feedback-changelog-expanded
description: CHANGELOG.md entries must be an expanded, extensive itemized list, not a short summary
metadata:
  type: feedback
---

`CHANGELOG.md` entries are always written as an expanded, extensive list: one bullet per
user-visible change with the concrete detail (names, symbols, behavior before/after, edge cases),
in the style of the 1.0.0 entry. Do not compress a feature into one or two summary bullets.

**Why**: the user stated this as a standing rule; the short summary written for the route-precedence
work was rejected.

**How to apply**: when adding to `[Unreleased]`, split by Keep a Changelog section
(Changed/Added/Deprecated/Fixed/Not supported) and list every distinct change, test and doc update.
