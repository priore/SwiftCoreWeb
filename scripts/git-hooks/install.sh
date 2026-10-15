#!/bin/sh
# SwiftCoreWeb — opt-in: enable the contributor git hooks in this clone.
set -eu
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath scripts/git-hooks
echo "Hooks enabled (core.hooksPath=scripts/git-hooks). Undo: git config --unset core.hooksPath"
