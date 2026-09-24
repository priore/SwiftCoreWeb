Note: cross-project generalizable memories live in `~/.claude/memory/` (separate index).

## Feedback (specific to this project)
- [Use AskUserQuestion for confirmations](feedback_askuserquestion_for_confirm.md) — yes/no confirmations must use AskUserQuestion tool, not free-text questions

## Project
- [SwiftCoreWebDashboard build/test command](dashboard-target-test-command.md) — needs xcodebuild + iOS Simulator destination, plain `swift test` can't compile it (UIKit)
- [CI: verify locally before pushing to GitHub](ci-local-before-remote-workflow.md) — run scripts/ci-local.sh green first, never round-trip fixes through remote CI; must use the exact CI Xcode version or the pass proves nothing

## Reference
- (none yet)
