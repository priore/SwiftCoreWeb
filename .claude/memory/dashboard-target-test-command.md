---
name: dashboard-target-test-command
description: How to build/test SwiftCoreWebDashboard target (UIKit dependency, plain `swift test` can't compile it)
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

See [[../Plans/DEVICE_DASHBOARD_PLAN.md]] step 2/5 for what's built so far.
