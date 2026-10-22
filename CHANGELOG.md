# Changelog

All notable changes to this project are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.2.0] - 2026-10-19

### Changed
- **Route precedence no longer depends on registration order.**
  - When several routes of the same method match a path, segments are compared left to right.
  - Ranking per segment: literal > constrained parameter > unconstrained parameter > optional parameter > catch-all.
  - The strictly more specific route wins.
  - A shorter route beats the same route with an optional tail (`/a` over `/a/{page?}`).
  - On an exact tie the first registered route still wins.
- **`@Controller` routes register their path with constraints intact.**
  - `/api/users/{id:int}` is registered instead of `/api/users/{id}`.
  - Constraints now take part in matching exactly as they do for closure `map*` routes.
  - A value that fails a constraint is now a `404` (or falls through to another matching route) instead of a `400` from parameter binding.
- **`@Controller` route values are converted to the handler parameter's declared type**, instead of a type derived from the constraint.
- **Ambiguous routes now fail at startup instead of silently shadowing each other.**
  - Applies to two routes of the same method and template shape.
  - Placeholder names are ignored: `/users/{id}` and `/users/{name}`, `/f/{*a}` and `/f/{*b}`, `/a/{x?}` and `/a/{y?}` are all ambiguous.
  - Before, the later route was silently left unreachable.
  - `runAsync()` and `TestHost` throw `AmbiguousRoutesError`.
  - Constraints are part of the shape, so `{id:int}` and `{id:uuid}` remain allowed.
  - Overlapping but different constraints are not reported; they are resolved by precedence.
- **Swift `Int64` is now a primitive bindable type** for route placeholders and query values (needed by the `long` constraint).

### Added
- **New route constraints**, accepted with the same syntax by the runtime router and by the `@Controller`/`@Get`/… macros:
  - Types: `long` (`Int64`), `bool` (exactly `true`/`false`), `double`, `alpha` (one or more ASCII letters).
  - Numeric bounds: `min(n)`, `max(n)`, `range(a,b)`.
  - String length: `length(n)`, `length(a,b)`, `minlength(n)`, `maxlength(n)`.
- **Constraint chaining.**
  - `{id:int:min(1)}` matches only when every constraint matches.
  - Whitespace around tokens and arguments is ignored.
  - Chains are supported on optional placeholders (`{page:int:min(1)?}`).
- **Registration-time validation of constraints.**
  - Rejected: unknown names, missing or extra arguments, non-integer arguments, empty ranges (`range(5,1)`), negative or inverted length bounds, and parenthesised parameterless constraints (`int(3)`).
  - Closure routes are rejected at registration.
  - Controllers are rejected with an invalid-route-template compile error.
- **Compile-time diagnostic for constraint/type mismatch in controllers.**
  - Triggered when a constraint cannot bind to the handler parameter's type (`{id:int}` with `id: UUID`, `{code:length(3)}` with `code: Int`).
  - The message lists the Swift types each constraint accepts.
- **`AmbiguousRoutesError`** (public, `CustomStringConvertible`).
  - `groups` holds the offending routes as `"GET /users/{id}"`.
  - The description lists every group, one route per line, with a hint on how to fix it.
- **`WebApplication.makeDispatcher() throws`**, the throwing replacement for `buildDispatcher()`.

### Deprecated
- **`WebApplication.buildDispatcher()`**: use `makeDispatcher()`.
  - The deprecated form keeps its signature.
  - It prints the route list to stderr and stops the process if routes are ambiguous.

### Fixed
- **`@Controller` with an unconstrained placeholder bound to a non-`String` parameter now compiles** (`{id}` with `id: Int`). Before, the generated code passed a `String` to the `Int` parameter.
- **`@Controller` duplicate-route check now compares the template shape.**
  - Before, it compared raw path strings.
  - It wrongly flagged `{id:int}` against `{id:uuid}`.
  - It missed `{id}` against `{name}`.

## [1.1.0] - 2026-09-26

### Added — Live Pages
- **`Page` protocol and `app.mapPage(...)`**: a server-rendered page model.
  - A `$swift('name')` call in the Vue template runs an `onEvent("name")` handler in Swift and re-renders.
  - No client-side JS or DOM code to write.
- **`form` (typed, `Codable`)** for user-edited fields bound with `v-model="form.x"`.
  - Everything else on the page struct is server state: visible to the browser for rendering, not client-modifiable.
  - The rendered snapshot is signed.
- **`VueTemplateCompiler`**: compiles `.html` Vue templates.
  - Dev mode recompiles on file mtime change.
  - Production caches the compiled output.
- **`/_framework/live.js`** client script, served automatically for pages using `mapPage`.
- **Session-scoped cookie helpers** and `ContentRoot.path` for locating page templates.
- **`HelloWorldApp` showcase** counter demo built on Live Pages.
- **Docs**: `docs/web/LIVE_PAGES_GUIDE.md`.

## [1.0.0] - 2026-09-24

First public release.

### Fixed
- **`Package.swift`: declared `.macOS(.v11)` alongside `.iOS(.v15)` in `platforms`.**
  - Without an explicit macOS platform, the `SwiftCoreWebMacros` target inherited the default macOS 10.13 deployment target.
  - That is too low for `SwiftSyntax`/`SwiftSyntaxBuilder`/`SwiftSyntaxMacros`/`SwiftDiagnostics`/`SwiftCompilerPlugin` (require 10.15+).
  - The main `SwiftCoreWeb` target also uses `os.Logger`/`OSLogMessage` (require macOS 11+).
  - Both broke every build on `master` and every Dependabot PR.
- **`ServerEngine.swift` and `SwiftCoreWebTesting/TestHost.swift`: Swift 6 strict concurrency fixes.**
  - Replaced `pipeline.addHandler`/`pipeline.context(name:)`/`pipeline.removeHandler(context:)`, which strict concurrency rejects.
  - Cause: `HTTPResponseEncoder`, `ByteToMessageHandler`, `WebSocketFrameEncoder` and `ChannelHandlerContext` have `@available(*, unavailable) extension _: Sendable` in swift-nio.
  - Now uses `pipeline.syncOperations.addHandler` run via `eventLoop.submit`/`.execute`.
  - Teardown uses `pipeline.removeHandler(name:)`.
- **CI (`.github/workflows/ci.yml`): `build-and-test` now uses `xcodebuild` against an iOS Simulator destination** instead of bare `swift build`/`swift test` (which targets macOS).
  - The package is iOS-only in intent: `SwiftCoreWebDashboard` imports `UIKit`.
  - A macOS-targeted build always failed with `no such module 'UIKit'`, independent of any source fix.
- **CI: `runs-on` switched to the `xcode-27` runner image** (Xcode 27.0 build 27A266a).
  - The job's toolchain now matches what is verified locally via `scripts/ci-local.sh`.
  - Avoids chasing simulator/runtime mismatches on `macos-15`.
- **`LifecycleSupport.swift`: `requestSingleAppMode()` is now `async`** and uses `withCheckedContinuation` instead of a `DispatchSemaphore` + captured `var`.
  - Swift 6 strict concurrency rejects mutating a captured var from the completion closure, which runs on a different isolation domain.

### Added — core `SwiftCoreWeb`
- **Server**: fluent Minimal-API-style HTTP/HTTPS/WebSocket server for iOS 15+.
  - Zero runtime reflection.
  - Built on a single `NIOTSListenerBootstrap` (Network.framework via `NIOTransportServices`).
  - Bridged to Swift Concurrency with `NIOAsyncChannel`.
- **Routing**:
  - Minimal API closures: `mapGet`/`mapPost`/`mapPut`/`mapPatch`/`mapDelete`/`mapHead`/`mapOptions`/`mapMethods`, grouped with `mapGroup(...).requireAuthorization()`.
  - Macro-based controllers: `@Controller`, `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route`, with compile-time `registerRoutes(into:)` and no runtime type discovery.
- **Route templates**:
  - Typed constraints (`{id:int}`, `{id:uuid}`), optional segments, catch-alls.
  - Automatic `HEAD` for every `GET`, automatic `OPTIONS`.
  - `405` on path-match/method-mismatch.
- **Handler parameter binding**:
  - Automatic for `HttpContext`, route values, JSON body and query string.
  - Explicit wrappers: `Header<T>`, `Query<T>`, `Service<T>`, `Form`.
  - Failed conversions produce a `400` `ProblemDetails`.
- **Compile-time route diagnostics with Fix-Its** for:
  - Unmatched placeholders/parameters.
  - Unsupported types.
  - Duplicate method+path.
  - Markers outside `@Controller`.
  - Non-`Sendable` controllers.
  - Invalid route syntax.
- **Middleware pipeline** (`IApplicationBuilder`-style, sequential `async`):
  - `useExceptionHandler` (RFC 9457 ProblemDetails).
  - `useCors`, `useSecurityHeaders`.
  - `useAuthentication` (JWT built-in, Basic, custom schemes), `useAuthorization(policies:)`.
  - `useStaticFiles`, `useRequestLogging`.
- **Traffic protection**: `RateLimiter` actor and `ConnectionGate` (max concurrent connections) gate traffic before handlers run.
- **Lifecycle awareness**:
  - `keepDeviceAwake`.
  - `bindToLifecycle()`: stop on background, restart on `.active`.
  - `requestSingleAppMode()` for kiosk/Autonomous Single App Mode.
- **TLS and secrets**:
  - TLS via `useHttps(p12:passwordKeychainKey:)`.
  - Secrets (JWT keys, `.p12` passwords) always come from the Keychain via `SecretStore`, never from JSON.
- **Configuration and services**:
  - `appsettings.json`/`appsettings.Development.json`, environment-aware (`.development`/`.production`).
  - Bonjour discovery (`advertise(name:)`).
  - Dependency injection (`builder.services`).
- **Web hosting**:
  - Zero-build Vue 3 (`app.useVue()`, bundled SPM resource, no build step) or full Vite + `.vue` workflow.
  - `useStaticFiles`/`useSpa` with `ETag`/`Range`/precompressed-sidecar support.
  - `[[ ]]`-delimited server-side template engine that stays out of Vue's `{{ }}` syntax.
- **Realtime**: `mapSse` and `mapWebSocket`.
- **API docs**: `mapOpenApi(...)` serves `/openapi.json` from compile-time route metadata, with schemas via `@ApiModel` (no reflection).
- **`ServerMetrics`**: in-memory counters and a fixed-size ring of recent requests, covering:
  - Totals and requests per second.
  - Latency (mean/p50/p95/max).
  - Status-class breakdown.
  - Rate-limit and connection-cap rejections.
  - Active connections and active WebSockets.
  - Byte throughput, rebind count, uptime.
- **`SwiftCoreWebTesting.TestHost`**:
  - Runs the exact same handler chain as production (routing, middleware, auth, handlers) over an in-memory `NIOAsyncTestingChannel`.
  - Helpers: `get`/`post`/`put`/`patch`/`delete`/`head`/`options`.
  - `TestResponse.decode` and `bodyString`.

### Added — `SwiftCoreWebDashboard` (opt-in, separate target)
- **On-device SwiftUI console** replacing the app's screen with a live view of the server.
  - Two styles: Mission Control (dense NOC-style) and Native Cards (iOS-native look).
  - Switchable at runtime and persisted, no rebuild needed.
- **Device metrics sampler** (1 Hz, public APIs only):
  - CPU (system + per-process), memory footprint.
  - `ProcessInfo.thermalState`.
  - Battery level/state and Low Power Mode.
  - Storage free/total.
  - Network path/interface/throughput.
  - System and app uptime.
- **SQLite-backed history** (system `libsqlite3`, no SPM dependency).
  - Retention: 24h per minute, 7d per hour, 30d per day.
  - Automatic rollup and pruning.
- **Operations UI**: QR code of the server's LAN URL, Start/Stop/Restart controls, live request log.
- **Opt-in `mapMetrics(_:)`**: HTTP endpoint (JSON) plus an SSE stream, off by default.
- **Honest about platform limits**: documents what iOS does *not* expose publicly (CPU/battery °C, GPU %, Wi-Fi SSID) rather than simulating it.

### Added — showcase & docs
- **`HelloWorldApp` showcase** demonstrating the dashboard as the app's default on-device screen, with `/` still serving `www/index.html` to browsers.
- **README documentation**:
  - Course-style walkthrough for the dashboard.
  - App Store review notes (Info.plist keys, local-network prompt, what to protect).
  - .NET-to-SwiftCoreWeb naming table.
- **Screenshots**: side-by-side dashboard style comparison (`docs/screenshots/`).

### Security & compliance
- **No hardcoded credentials** anywhere in the package: JWT signing keys and `.p12` passwords are Keychain-only via `SecretStore`.
- **Built-in security middleware**: `useSecurityHeaders()` and `useAuthentication`/`useAuthorization` are part of the core pipeline.
- **Flood protection by default**: `RateLimiter` and `ConnectionGate` guard against request floods and connection exhaustion.
- **Personal data handling**:
  - Dashboard history stores only aggregates, never client IPs or request paths.
  - `ServerMetrics`' recent-request ring (IPs included) stays in memory only, never persisted.
- **`mapMetrics` documented as requiring `auth:`** on untrusted LANs.
- **Legal/security scaffolding**: `LICENSE` (PolyForm Noncommercial 1.0.0), `LICENSE-THIRD-PARTY`, `CLA.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`.
- **CI**:
  - Build/test workflow.
  - Dependabot (Swift + GitHub Actions ecosystems).
  - gitleaks secret scanning on every push/PR.
  - OpenSSF Scorecard.
  - CLA Assistant bot.
- **Publishing pipeline** keeps internal-only material out of the public history.
