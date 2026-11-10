---
name: build-test-commands
description: Why plain swift build/test fails on this repo and the xcodebuild commands that work, including the macros-on-host quirk
metadata:
  type: project
---

`swift` on PATH is an old swiftly toolchain that cannot read the Swift 6 manifest. Even with Xcode's toolchain,
`swift build`/`swift test` compile every target and `SwiftCoreWebDashboard` imports UIKit, so everything
(including core tests) must go through `xcodebuild` on an iOS Simulator destination. CI itself only uses `xcodebuild`.
The Dashboard scheme has no test action: use the aggregate `SwiftCoreWeb-Package` scheme with `-only-testing:`.

`SwiftCoreWebMacrosTests` is built for macOS only. A simulator run silently executes a stale
`Debug-iphonesimulator/...xctest` from DerivedData (green but without new tests), or fails with
"Failed to create a bundle instance" when none exists. Build with `build-for-testing`, then run the macOS
bundle with `xcrun xctest` (commands in skill `test-target`). `ci.yml` skips the macros bundle in the simulator
run and executes the host bundle in a separate step.

Quick full check: `scripts/ci-local.sh` (see [[ci-local-before-remote-workflow]]).
