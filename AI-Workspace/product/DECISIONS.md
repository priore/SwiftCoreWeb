# Design Decisions

## Overview

This replaces a previous draft of generic, unverifiable decisions ("Modular Architecture was chosen...", "Hybrid Approach was chosen...") with decisions actually traceable to the project's prompts and code. Each entry below is either 🟢 confirmed by a comment/log in the repository, or explicitly marked otherwise.

## Decision Log

### D001: Single network stack — SwiftNIO + NIOTransportServices, not FlyingFox

**Context:** An earlier discarded design specified FlyingFox + GRDB for an iOS container app (that prompt has since been removed from `Prompts/`; see the historical note below). The project pivoted to a different, broader goal: a standalone SPM framework ([framework_http_server_prompt.md](../Prompts/framework_http_server_prompt.md)).

**Decision:** Use SwiftNIO (`NIOCore`, `NIOHTTP1`, `NIOWebSocket`) on `NIOTransportServices` for HTTP, HTTPS and WebSocket in one bootstrap, bridged to `async`/`await` via `NIOAsyncChannel`. No FlyingFox, no GRDB, no second transport for TLS.

**Consequences:** No SQLite/GRDB persistence layer exists in the core `SwiftCoreWeb` library — any
storage is the embedding app's responsibility. TLS reuses the same listener instead of a separate
stack. (The optional `SwiftCoreWebDashboard` product later adds its own system-`libsqlite3` usage,
not GRDB, scoped to that product only — see D006 below.) 🟢 (See [decisions historical note](#historical-note-discarded-flyingfoxgrdb-design) below and [ARCHITECTURE.md](../architecture/ARCHITECTURE.md).)

### D002: Zero-reflection macros for routing, not runtime discovery

**Context:** Declarative routing (`@Get`, `@Post`, `@Controller`) needed a mechanism with no `Mirror`-based runtime type discovery, per the framework's junior-developer/compile-time-safety goal.

**Decision:** `@Controller` (member + extension macro) generates `static func registerRoutes(into:)` and `RouteProvider` conformance at compile time; method markers are peer macros that validate and emit no code. Registration stays explicit (`app.mapControllers(...)`).

**Consequences:** Compile-time diagnostics with Fix-Its are possible (duplicate routes, placeholder mismatches, non-`Sendable` controllers); no runtime reflection cost. A known swift-syntax 509.x limitation means "marker used outside `@Controller`" cannot be reliably diagnosed at the peer-macro layer — that check was removed after investigation rather than shipped broken (see [KNOWN_ISSUES.md](KNOWN_ISSUES.md)). 🟢

### D003: `Encodable` return values dispatch through one conversion function

**Context:** The closure `map*` overloads were originally generic over `T: HttpResultConvertible`; a plain `Encodable` DTO doesn't conform to that on its own, and Swift has no retroactive blanket conformance. Every such route silently returned `204 No Content` with an empty body instead of `200` JSON.

**Decision:** Loosen the generic constraint to `T: Sendable`; add `makeHttpResult(_:)` as the single call site both `map*` implementations funnel through, dispatching `HttpResultConvertible` first, then any `Encodable` via `JSONEncoder`.

**Consequences:** Fixed at the root (one function), not patched per call site. 🟢 (`Sources/SwiftCoreWeb/HttpResponse.swift`, `MinimalApiRouting.swift`, `Router.swift`)

### D004: Pin `swift-collections` to `exact: "1.6.0"`

**Context:** swift-nio's transitive dependency `swift-collections` 1.7.0 calls `_swift_initBorrow`, a runtime symbol only present in macOS 27+'s `libswiftCore.dylib`. Test binaries failed to `dlopen` on an older host OS (confirmed against official Linux `swift:5.9`/`swift:6.0` Docker images too, ruling out a toolchain defect).

**Decision:** Pin the exact version in `Package.swift` rather than require an OS upgrade to run tests, with a `ponytail:` comment marking the pin and its removal condition.

**Consequences:** Tests run today on an older host OS; the pin must be revisited once the dev machine's OS is upgraded past the gap. 🟢

### D005: `ContinuousClock` replaced with `DispatchTime`

**Context:** `RateLimiter.swift` initially used `ContinuousClock`, which requires iOS 16+; the framework's floor is iOS 15.

**Decision:** Use `DispatchTime` instead.

**Consequences:** Rate limiter works down to the stated iOS 15 minimum deployment target. 🟢

### D006: On-device dashboard uses `ProcessInfo.thermalState` only, no private IOKit temperature APIs

**Context:** The on-device dashboard (`SwiftCoreWebDashboard`) wants to show device thermal health.
iOS has no public API for CPU/battery temperature in °C.

**Decision:** Surface only `ProcessInfo.thermalState` (nominal/fair/serious/critical) plus its change
timeline; never call private IOKit thermal sensors, never simulate a °C figure. The UI marks
CPU/battery °C, fan speed, GPU %, and Wi-Fi SSID explicitly as "not available" rather than
approximating them.

**Consequences:** Thermal display is coarse (4 states) but uses only public, App-Store-safe APIs.
🟢 (`Sources/SwiftCoreWebDashboard/DeviceMetrics.swift`, [DEVICE_DASHBOARD_PLAN.md](../Plans/DEVICE_DASHBOARD_PLAN.md))

### D007: Live Pages templates precompiled server-side via JavaScriptCore, snapshot signed with a per-process HMAC key

**Context:** Live Pages (`Page`/`mapPage`) needed a Vue template to render server-driven state
without the developer writing client JS, while `useSecurityHeaders()` sets `default-src 'self'`
(no `unsafe-eval`) — Vue's runtime template compiler uses `Function("Vue", code)`, which that CSP
blocks. A gate spike (`AI-Workspace/Plans/LIVE_PAGES_PLAN.md` step 1) needed to confirm a
CSP-compatible alternative existed before the rest of the feature was built.

**Decision:** Compile templates on the server with the vendored `@vue/compiler-dom` browser build
evaluated in a `JSContext` (JavaScriptCore, iOS 7+, no new platform requirement), serving the output
as an external classic script (`GET /_live/<page>.js`) — allowed by the CSP since it's same-origin
and never `eval`-based. Server state round-trips as a JSON snapshot the client treats as opaque,
signed with HMAC-SHA256 (`CryptoKit`) under a `SymmetricKey` generated once per process (no key on
disk), verified with `HMAC<SHA256>.isValidAuthenticationCode` (constant-time).

**Consequences:** Gate confirmed on both JavaScriptCore (macOS) and real WebKit/Safari with the CSP
active before the rest of Live Pages was implemented — no `unsafe-eval` fallback needed. Pages reload
after a server restart (the signing key isn't persisted) — `// ponytail:` comment in `Pages.swift`
marks the upgrade path (Keychain) if that's ever needed. 🟢 (`Sources/SwiftCoreWeb/Pages.swift`,
`VueTemplateCompiler.swift`, `AI-Workspace/Plans/LIVE_PAGES_PLAN.md`)

## Historical note: discarded FlyingFox/GRDB design

An earlier prompt (`app_http_server_prompt.md`) specified an entirely different architecture (FlyingFox HTTP server, GRDB/SQLite in WAL mode, a `DDoSCoordinator` actor, Google OAuth admin dashboard, Discord/Telegram alerting, social-API helper SDK). **None of this was implemented** — it never appeared anywhere in `Sources/`. It predated and was superseded by `framework_http_server_prompt.md`, and has since been removed from `Prompts/`. Earlier drafts of several AI-Workspace documents appear to have drawn on this discarded prompt or on generic templates instead of the actual code; those documents have since been corrected. 🟢

## Review Checklist

- Completeness
  - [x] Every decision traceable to a prompt comment, code comment, or file
- Accuracy
  - [x] Verified against `Package.swift` and named source files (2026-09-24)
- Consistency
  - [x] Aligned with [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) and [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
- TODO
  - [ ] Add new entries only when a future decision has an equivalent traceable source
- Missing information
  - [ ] None at this time
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code/prompts
