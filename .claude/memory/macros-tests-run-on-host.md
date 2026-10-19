---
name: macros-tests-run-on-host
description: SwiftCoreWebMacrosTests only build for macOS; the simulator run silently executes a stale bundle, so run the host xctest directly
metadata:
  type: project
---

Under the `SwiftCoreWeb-Package` scheme, `SwiftCoreWebMacrosTests` is built for macOS
(`Build/Products/Debug/`), never for the iOS Simulator. `xcodebuild test ... -only-testing:SwiftCoreWebMacrosTests`
on a simulator destination therefore runs whatever stale `Debug-iphonesimulator/SwiftCoreWebMacrosTests.xctest`
is already in DerivedData (green, but without new tests); with no stale bundle it fails with
"Failed to create a bundle instance".

Reliable way to run them:
1. `xcodebuild build-for-testing -scheme SwiftCoreWeb-Package -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:SwiftCoreWebMacrosTests`
2. `xcrun xctest ~/Library/Developer/Xcode/DerivedData/SwiftCoreWeb-*/Build/Products/Debug/SwiftCoreWebMacrosTests.xctest`

Also: `swift` on PATH may be a swiftly 5.0.x toolchain that cannot read the Swift 6 manifest, and
`swift test` builds every target (Dashboard needs UIKit), so use xcodebuild as above.
Remote CI was already red before the route-precedence work; `scripts/ci-local.sh` reports the same
missing-bundle failure on a clean DerivedData.
