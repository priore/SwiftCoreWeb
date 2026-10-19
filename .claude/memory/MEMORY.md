## Feedback (specific to this project)

## Project
- [SwiftCoreWebDashboard build/test command](dashboard-target-test-command.md) — needs xcodebuild + iOS Simulator destination, plain `swift test` can't compile it (UIKit)
- [CI: verify locally before pushing to GitHub](ci-local-before-remote-workflow.md) — run scripts/ci-local.sh green first, never round-trip fixes through remote CI; must use the exact CI Xcode version or the pass proves nothing

## Reference
- (none yet)
- [Macros tests run on the host](macros-tests-run-on-host.md) — sim run executes a stale bundle; build-for-testing then `xcrun xctest` the macOS bundle
