---
name: test-target
description: Run the tests of one SwiftCoreWeb target (core, dashboard, macros) with the commands that actually work on this repo.
---

# test-target

Plain `swift test` does not work on this repo (see memory `build-test-commands`). Run from the repo root:

- core: `xcodebuild test -skipMacroValidation -scheme SwiftCoreWeb-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SwiftCoreWebTests`
- dashboard: same command with `-only-testing:SwiftCoreWebDashboardTests`
- macros (built for macOS, never for the simulator):
  1. `xcodebuild build-for-testing -skipMacroValidation -scheme SwiftCoreWeb-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SwiftCoreWebMacrosTests`
  2. `xcrun xctest "$(find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Debug/SwiftCoreWebMacrosTests.xctest' -not -path '*/SourcePackages/*' -maxdepth 6 | head -1)"`

Run the full suite with `scripts/ci-local.sh` (skill `ci-local`) before pushing.
