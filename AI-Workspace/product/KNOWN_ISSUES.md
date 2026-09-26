# Known Issues

## Overview

This replaces a previous draft of generic, unverifiable issues ("macro system limitations", "web technology integration challenges" with no specifics). Below are the issues actually traceable to code comments and the generation log in [framework_http_server_prompt.md](../Prompts/framework_http_server_prompt.md).

## Active / Accepted Limitations

### I001: `swift-collections` pinned to `exact: "1.6.0"`

**Description:** swift-nio's transitive dependency `swift-collections` 1.7.0 calls `_swift_initBorrow`, a runtime symbol only present in macOS 27+'s `libswiftCore.dylib`. On an older host OS, test binaries fail to `dlopen`.

**Impact:** Tests only run on this pinned version until the development machine's OS is upgraded.

**Status:** Accepted, tracked via a `ponytail:` comment in `Package.swift` marking removal once the OS gap closes. 🟢

### I002: "Marker macro outside `@Controller`" diagnostic cannot be implemented

**Description:** `RouteMethodMacro.swift` originally checked `declaration.parent` to diagnose a method-marker macro (`@Get`, etc.) used outside a `@Controller` type. `declaration.parent` is always `nil` for a `PeerMacro` — swift-syntax hands it a `detach()`ed node — so the check never worked.

**Impact:** Misuse of a marker macro outside `@Controller` will not produce a dedicated compile-time diagnostic; it will surface as a different/generic error instead.

**Status:** Removed rather than shipped broken. Documented as not implementable at this layer on swift-syntax 509.x. 🟢

### I003: HTTP/2 not implemented

**Description:** Optional HTTP/2 over TLS (`NIOHTTP2`) is explicitly out of scope for v1.

**Impact:** No HTTP/2 support today.

**Status:** By design; the framework's architecture is stated to not block adding it later. 🟢

### I004: Live Pages state is visible to the client, requires JavaScript, and has no file upload

**Description:** A `Page`'s entire encoded state ships to the browser in the signed snapshot (needed
so Vue can render it) — it is tamper-proof, not secret. The signing key is per-process
(`// ponytail:` comment, `Pages.swift`), so pages reload after a server restart. Sessions
(`useSession()`) are in-memory, single-process. There is no file upload support. The page is inert
without JavaScript (no server-rendered fallback markup for `Page` templates).

**Impact:** Don't put secrets in page state; don't rely on Live Pages surviving a restart or working
without JS; use a plain route for file uploads.

**Status:** By design, documented in `AI-Workspace/Plans/LIVE_PAGES_PLAN.md` ("Fuori scope") and in
`docs/web/LIVE_PAGES_GUIDE.md`. 🟢 (`Sources/SwiftCoreWeb/Pages.swift`, `Session.swift`)

## Resolved Issues (fixed during the delivery log, kept for history)

### R001: `Encodable` DTO routes silently returned empty `204` instead of `200` JSON

Root cause: the `map*` overloads were generic over `T: HttpResultConvertible`, which a plain `Encodable` struct doesn't conform to. Fixed via a single `makeHttpResult(_:)` dispatch point. See [DECISIONS.md#d003](DECISIONS.md#d003-encodable-return-values-dispatch-through-one-conversion-function). 🟢

### R002: Missing `import CompilerPluginSupport` broke the macro target build

Root cause: `.macro(...)` target sugar lives in `CompilerPluginSupport`, not `PackageDescription`. A one-line manifest fix; reproduced and confirmed on official Linux `swift:5.9`/`swift:6.0` Docker images, ruling out a toolchain defect. 🟢

### R003: `ContinuousClock` used in `RateLimiter.swift` required iOS 16+

Replaced with `DispatchTime` to keep the iOS 15 floor. 🟢

### R004: Pre-GA `NIOAsyncChannel` member names / `NSLock` in async context

`inboundStream`/`outboundWriter` renamed to `inbound`/`outbound`; `NSLock` replaced with `NIOLockedValueBox` in `WebSocketSupport.swift`/`ServerEngine.swift`. 🟢

## Review Checklist

- Completeness
  - [x] Every issue traceable to a code comment or the generation log
- Accuracy
  - [x] Verified against `Package.swift` and `Sources/SwiftCoreWebMacros/RouteMethodMacro.swift` comments (2026-09-24)
- Consistency
  - [x] Aligned with [DECISIONS.md](DECISIONS.md)
- TODO
  - [ ] Add new issues only when traceable to a real code comment, test failure, or bug report
- Missing information
  - [ ] No independent re-run of `swift build`/`swift test` performed in this review — status relies on the prompt's own log
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code
