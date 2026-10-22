---
name: dashboard-target-test-command
description: Plain `swift test` never works on this repo (UIKit in Dashboard, swiftly 5.0.3 on PATH) — don't install/configure anything, run scripts/ci-local.sh or xcodebuild
metadata:
  type: project
---

`SwiftCoreWebDashboard` imports UIKit, so plain `swift build`/`swift test` on
macOS fails with "unable to resolve module dependency: 'UIKit'" (SPM builds
for the host by default, ignoring the package's `platforms: [.iOS(.v15)]`).

`swift test`/`swift build` build the WHOLE package (all targets), so this
blocks even `SwiftCoreWebTests` (core, no UIKit) — not just the dashboard
target. Use xcodebuild against an iOS Simulator destination for everything:
- Build only: `xcodebuild build -scheme SwiftCoreWebDashboard -destination 'platform=iOS Simulator,name=iPhone 17'`
- Tests: the `SwiftCoreWebDashboard` scheme has no test action configured;
  use the aggregate package scheme instead:
  `xcodebuild test -scheme SwiftCoreWeb-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SwiftCoreWebDashboardTests`
  `xcodebuild test -scheme SwiftCoreWeb-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SwiftCoreWebTests`

Also, `swift` on PATH is `~/.swiftly/bin/swift` (5.0.3), which cannot read the Swift 6
manifest. Even with Xcode's toolchain the UIKit failure remains, so there is nothing to
install or configure: CI itself only uses `xcodebuild`. Quickest full check: `sh scripts/ci-local.sh`
(see [[ci-local-before-remote-workflow]]); macro tests: [[macros-tests-run-on-host]].

See [[../Plans/DEVICE_DASHBOARD_PLAN.md]] step 2/5 for what's built so far.
