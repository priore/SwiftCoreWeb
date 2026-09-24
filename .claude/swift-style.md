# Swift Style Guide — SwiftCoreWeb

Read before writing or modifying any `*.swift` code. This is a server-side networking library
(swift-nio based), not an app: no UIKit/SwiftUI concerns apply here.

**Exception:** `Sources/SwiftCoreWebDashboard/` (the optional on-device dashboard product) is
SwiftUI throughout — `@MainActor`/`ObservableObject` view models, `View`/`Path`/`Shape` UI code.
The no-UIKit/SwiftUI rule above applies only to `Sources/SwiftCoreWeb/` (the core networking
library) and `Sources/SwiftCoreWebMacros/`.

## General
- Naming & logic: all identifiers, protocols, and architectural comments in English. Concise
  logical comments, only where intent isn't obvious from the code.
- Public API surface must stay fluent/Minimal-API style (see README Hello World) — new builder
  methods should read naturally in a chained call (`app.mapGet(...)`, `builder.listenOnAllInterfaces()`).
- Structure: modular via `extension` to separate concerns/protocols, matching existing file layout
  under `Sources/SwiftCoreWeb`.

## Concurrency (Swift 6, strict mode)
- Async/await priority. No `DispatchQueue` or `asyncAfter`.
- `@MainActor` only where UI-adjacent (rare in this target); prefer actor isolation or plain
  `Sendable` value types for NIO event-loop-bound state.
- Force explicit `@Sendable` on closures escaping to async contexts — catches isolation leaks at
  compile time, important since NIO channel callbacks cross threads.
- Minimize actor hopping: batch work before crossing an event-loop/actor boundary.
- Prevent retain cycles in closures held by long-lived NIO channel handlers (`weak self`/`unowned self`).

## Macros (`Sources/SwiftCoreWebMacros`)
- Zero runtime cost is a hard constraint: macros only generate code at compile time, never
  introduce runtime reflection.
- Any macro behavior change needs a matching test in `Tests/SwiftCoreWebMacrosTests`
  (`ControllerMacroTests.swift` is the existing pattern to follow).

## Dependencies
- Everything not networking/macros (TLS, JWT, logging, network monitoring) uses system frameworks
  (`Security`, `CryptoKit`, `os.Logger`, `Network`) — don't add a third-party dependency for what
  a system framework already covers.
- Check `Package.swift` comments before touching a pinned dependency version — a pin may exist for
  a documented runtime-compatibility reason (see the `swift-collections` pin).

## Verification
- Check memory safety boundaries and Sendable/actor-isolation constraints before output.
- Run the relevant test target (`SwiftCoreWebTests` or `SwiftCoreWebMacrosTests`) after changes,
  not just a build.
