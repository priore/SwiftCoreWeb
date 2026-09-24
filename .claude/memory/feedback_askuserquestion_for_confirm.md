---
name: feedback-askuserquestion-for-confirm
description: Yes/no confirmations (proceed with action X?) must use AskUserQuestion, not free text
metadata:
  type: feedback
---

When a yes/no confirmation is needed before an action (e.g. publishing a release, force-pushing,
deleting a file), use the AskUserQuestion tool with Yes/No options, not a free-text question in chat.

**Why:** a free-text question forces the user to type a reply that costs a new prompt/tokens; a
choice box is faster to answer.

**How to apply:** applies to any binary confirmation before a risky or costly action (e.g. tagging
a release, publishing to a package registry, deleting/overwriting a file).
