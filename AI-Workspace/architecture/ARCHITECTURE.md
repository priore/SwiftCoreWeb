# System Architecture

## Overview

SwiftCoreWeb is an embedded HTTP/HTTPS/WebSocket web framework for iOS 15+, distributed as a Swift Package. It is not an app: it is a library an iOS app links to start a local server inside its own process. Developer experience is modeled on .NET Core Minimal APIs (`WebApplication.createBuilder()`, `mapGet`, middleware pipeline) reimplemented in idiomatic Swift. 🟢

## SPM Targets

| Target | Path | Role |
|---|---|---|
| `SwiftCoreWeb` | `Sources/SwiftCoreWeb/` | Core library: server engine, routing, middleware, auth, static/SPA hosting, WebSocket/SSE, OpenAPI. |
| `SwiftCoreWebMacros` | `Sources/SwiftCoreWebMacros/` | Compiler plugin (`SwiftSyntax`) implementing `@Controller`, `@Get`/`@Post`/etc., `@ApiModel`. |
| `SwiftCoreWebTesting` | `Sources/SwiftCoreWebTesting/` | `TestHost`: runs the full request pipeline in memory, no sockets. |
| `SwiftCoreWebDashboard` | `Sources/SwiftCoreWebDashboard/` | Optional SwiftUI product: on-device server/device console (see [Dashboard](#on-device-dashboard-swiftcorewebdashboard) below). |

Four products are exposed: `SwiftCoreWeb`, `SwiftCoreWebTesting`, and `SwiftCoreWebDashboard`. `SwiftCoreWebMacros` is a `.macro` plugin target, not a public product. 🟢 (`Package.swift`)

## Dependency Policy

Only three external packages: `swift-nio`, `swift-nio-transport-services`, `swift-syntax` (macros only). `swift-collections` is pulled in transitively by swift-nio and pinned to `exact: "1.6.0"` — a `ponytail:` comment in `Package.swift` explains this works around a runtime symbol (`_swift_initBorrow`) missing on macOS versions before 27. Everything else uses system frameworks: CryptoKit, Security, `os.Logger`, `Network`. No JWT library, no crypto library, no third-party HTTP server (FlyingFox was an earlier, discarded design — see [decisions](../product/DECISIONS.md#historical-note-discarded-flyingfoxgrdb-design)). 🟢

## Network Stack

One transport for HTTP, HTTPS and WebSocket: SwiftNIO (`NIOCore`, `NIOHTTP1`, `NIOWebSocket`) running on `NIOTransportServices` (`NIOTSListenerBootstrap`), backed by `Network.framework`. HTTPS is the same bootstrap with TLS enabled via `NWProtocolTLS.Options`, loading the identity from a `.p12` (`SecPKCS12Import`) — no OpenSSL, no second stack. NIO is bridged to Swift Concurrency with `NIOAsyncChannel`, so public handler code is plain `async throws`; `EventLoopFuture` never appears in the public API. 🟢 (`Sources/SwiftCoreWeb/ServerEngine.swift`)

## Request Flow

1. Connection accepted by the NIOTS listener; `RateLimiter` (token bucket per IP) and the connection cap gate it before any body bytes are read — over-limit traffic gets `429`/`503` immediately (`Sources/SwiftCoreWeb/RateLimiter.swift`).
2. `MiddlewarePipeline` runs in registration order: exception handler → CORS → security headers → authentication → authorization → static files/SPA → request logging (`Sources/SwiftCoreWeb/MiddlewarePipeline.swift` and sibling `*Middleware.swift` files).
3. `Router` matches the request against templates registered via closures (`mapGet`, etc.) or macro-generated controller registrations (`Sources/SwiftCoreWeb/Router.swift`, `RouteRegistry.swift`, `RouteTemplateMatcher.swift`).
4. `ParameterBinding` resolves handler parameters from route values, query string, JSON body, or explicit wrappers (`Header<T>`, `Query<T>`, `Service<T>`) (`Sources/SwiftCoreWeb/ParameterBinding.swift`).
5. `RequestDispatcher` invokes the handler and converts the return value to an `HttpResponse` (`Sources/SwiftCoreWeb/RequestDispatcher.swift`).
6. Response flows back out through the pipeline; `ExceptionHandlerMiddleware` catches anything thrown and returns RFC 9457 ProblemDetails JSON. 🟢

## Macro System (Zero Runtime Reflection)

`@Controller` (member + extension macro) inspects annotated methods and generates `static func registerRoutes(into:)` plus `RouteProvider` conformance — the only macro that generates registration code. Method markers (`@Get`, `@Post`, `@Put`, `@Patch`, `@Delete`, `@Head`, `@Options`, generic `@Route`) are peer macros that validate and emit no code themselves. `Mirror` and runtime type discovery are never used; registration is explicit via `app.mapControllers(UserController.self, ...)`. 🟢 (`Sources/SwiftCoreWebMacros/ControllerMacro.swift`, `RouteMethodMacro.swift`)

## Concurrency Model

The built router is immutable after `.build()` (a `Sendable` value, lock-free on reads). Connection registry, rate limiter, and the live-reload hub are actors. Strict Swift 6 concurrency checking applies throughout; all handlers are `@Sendable`. 🟢

## Web Hosting (Vue 3)

Vue 3 is the supported frontend, embedded as a package resource (`vue.esm-browser.prod.js`) and served at `/_framework/vue.js` — no build step required for the zero-build path. `.useStaticFiles()` and `.useSpa()` (history-mode SPA fallback) serve compiled Vue apps; a server-side `[[ ]]`-delimited template engine coexists with Vue's `{{ }}` without collision. This is server-side asset hosting, not a native SwiftUI component system. 🟢 (`Sources/SwiftCoreWeb/VueRuntime.swift`, `SpaHosting.swift`, `StaticFiles.swift`, `TemplateEngine.swift`)

## On-device Dashboard (`SwiftCoreWebDashboard`)

Optional SwiftUI product, opt-in, kept out of the core library so `SwiftCoreWeb` stays free of
UIKit/SwiftUI (see the exception noted in [swift-style.md](../../.claude/swift-style.md)). Replaces
only the device's own screen (a server console: live metrics, device health, history) — the served
`/` page is unaffected, still plain HTML for browsers. Two interchangeable SwiftUI styles (Mission
Control / Native Cards), switchable at runtime, persisted in `UserDefaults`
(`Sources/SwiftCoreWebDashboard/DashboardStyle.swift`). Server-side metrics live in the core
(`ServerMetrics`, `WebApplication.metrics`); the dashboard target adds device sampling
(`DeviceMetrics.swift`, mach/`ProcessInfo`/`NWPathMonitor` APIs, 1 Hz) and history persistence
(`MetricsHistory.swift`, system `libsqlite3` — no SPM dependency, WAL mode, rollup + pruning to
24h/7d/30d). Optional HTTP surface: `app.mapMetrics(path:)` exposes the same metrics as JSON + SSE
for external consumers, disabled unless called explicitly. The showcase app
(`Showcase/HelloWorldApp/`) uses this dashboard as its default screen instead of a `WKWebView`. 🟢
(`Sources/SwiftCoreWebDashboard/`, `Package.swift`, [DEVICE_DASHBOARD_PLAN.md](../Plans/DEVICE_DASHBOARD_PLAN.md))

## Live Pages (server-rendered Vue, Livewire-style)

`Page`/`mapPage` (`Sources/SwiftCoreWeb/Pages.swift`) let a Vue template be driven entirely by Swift
state, no client-side JS written by the developer. Templates are precompiled **on the server** via
`VueTemplateCompiler` (`Sources/SwiftCoreWeb/VueTemplateCompiler.swift`): a lazy `JSContext`
(JavaScriptCore) evaluates the vendored `@vue/compiler-dom` browser build and calls
`VueCompilerDOM.compile(template, { hoistStatic: true })`, cached per template name and
mtime-invalidated only in `.development`. This avoids the browser ever running `Function("Vue",
code)`, which a strict `default-src 'self'` CSP (`useSecurityHeaders()`) blocks — confirmed against
real WebKit/Safari, see `AI-Workspace/Plans/LIVE_PAGES_PLAN.md` step 1. The compiled render function
is served as a classic script at `GET /_live/<page>.js`, registered once per page/`WebApplication`.

Each event round-trip: the client (`/_framework/live.js`, served by `useVue()`) posts
`{ snapshot, checksum, form, event, args }`; the server verifies `checksum` (HMAC-SHA256,
constant-time, per-process `SymmetricKey`), decodes the previous state from `snapshot`, overlays
`form` field-by-field (a field that fails to decode keeps its old value and lands in
`PageContext.errors`, never a 400), runs `onEvent`, and replies with a new signed snapshot (or a
`redirect`). Antiforgery: an `__scw_af` cookie minted on first `GET`, checked against the snapshot's
`af` on every `POST`. `PagesRootBox`/`LiveScriptRegistry`/`PagesCompilerBox` are keyed per
`ObjectIdentifier(WebApplication)` (multiple `WebApplication`s share a process in `TestHost`); the
HMAC signing key stays process-wide. 🟢 (`Sources/SwiftCoreWeb/Pages.swift`,
`VueTemplateCompiler.swift`, `VueRuntime.swift`, `AI-Workspace/Plans/LIVE_PAGES_PLAN.md`)

## Lifecycle & iOS Integration

`NetworkWatchdog` (`NWPathMonitor`) rebinds listeners on interface/IP change. `LifecycleSupport` provides `bindToLifecycle()` plus keep-awake (`isIdleTimerDisabled`) and optional screen-dimming helpers; the showcase app additionally wires SwiftUI's `ScenePhase` directly (see [Showcase/ShowcaseApp/Sources/ShowcaseRootView.swift](../../Showcase/ShowcaseApp/Sources/ShowcaseRootView.swift)) to start/stop the server as the app foregrounds/backgrounds. `stopAsync(timeout:)` drains in-flight requests before closing sockets. 🟢

## Testing

`SwiftCoreWebTesting.TestHost` runs the full middleware/routing/dispatch chain in memory via NIO's `NIOAsyncTestingChannel`, with no real sockets — the same code path as production. Used by `Tests/SwiftCoreWebTests/TestHostTests.swift`; macro expansion and diagnostics are covered separately by `Tests/SwiftCoreWebMacrosTests/ControllerMacroTests.swift` via `assertMacroExpansion`. 🟢

## What this document intentionally omits

There is no SwiftUI component library, no "Presentation/Domain/Infrastructure" layering, and no native UI design system inside this framework — SwiftCoreWeb is a server, not an app. UI concerns (if any) belong to whatever iOS app embeds it; the only UI code in this repository is the minimal showcase shell (`Showcase/ShowcaseApp/`). See [UI_ANALYSIS.md](../UI_ANALYSIS.md) for what that actually contains.

## Review Checklist

- Completeness
  - [x] SPM target layout documented
  - [x] Dependency policy documented
  - [x] Request flow traced end to end
  - [x] Macro system documented
  - [x] Concurrency model documented
- Accuracy
  - [x] Verified against `Package.swift` and `Sources/` file layout (2026-09-24)
- Consistency
  - [x] Terminology matches `framework_http_server_prompt.md`
- TODO
  - [ ] Re-verify after any structural change to `Sources/SwiftCoreWeb/`
- Missing information
  - [ ] Per-file internal design notes (would require reading every source file in full; out of scope for an architecture overview)
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code (Package.swift, Sources/ file listing, key source files read directly)
