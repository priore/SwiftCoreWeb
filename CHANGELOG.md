# Changelog

All notable changes to this project are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-09-24

First public release.

### Fixed
- `Package.swift`: declared `.macOS(.v11)` alongside `.iOS(.v15)` in `platforms`. Without an explicit macOS platform, the `SwiftCoreWebMacros` target inherited the default macOS 10.13 deployment target — too low for `SwiftSyntax`/`SwiftSyntaxBuilder`/`SwiftSyntaxMacros`/`SwiftDiagnostics`/`SwiftCompilerPlugin` (require 10.15+) — and the main `SwiftCoreWeb` target uses `os.Logger`/`OSLogMessage` (require macOS 11+). Both broke every build on `master` and every Dependabot PR.

### Added — core `SwiftCoreWeb`
- Fluent Minimal-API-style HTTP/HTTPS/WebSocket server for iOS 15+, zero runtime reflection, built on a single `NIOTSListenerBootstrap` (Network.framework via `NIOTransportServices`) bridged to Swift Concurrency with `NIOAsyncChannel`.
- Routing: Minimal API closures (`mapGet`/`mapPost`/`mapPut`/`mapPatch`/`mapDelete`/`mapHead`/`mapOptions`/`mapMethods`, grouped with `mapGroup(...).requireAuthorization()`) and macro-based controllers (`@Controller`, `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route`, compile-time `registerRoutes(into:)`, no runtime type discovery).
- Route templates with typed constraints (`{id:int}`, `{id:uuid}`), optional segments, catch-alls; automatic `HEAD` for every `GET`, automatic `OPTIONS`, `405` on path-match/method-mismatch.
- Automatic handler parameter binding (`HttpContext`, route values, JSON body, query string) plus explicit `Header<T>`/`Query<T>`/`Service<T>`/`Form`; failed conversions produce a `400` `ProblemDetails`.
- Compile-time route diagnostics with Fix-Its: unmatched placeholders/parameters, unsupported types, duplicate method+path, markers outside `@Controller`, non-`Sendable` controllers, invalid route syntax.
- Middleware pipeline (`IApplicationBuilder`-style, sequential `async`): `useExceptionHandler` (RFC 9457 ProblemDetails), `useCors`, `useSecurityHeaders`, `useAuthentication` (JWT built-in, Basic, custom schemes), `useAuthorization(policies:)`, `useStaticFiles`, `useRequestLogging`.
- `RateLimiter` actor and `ConnectionGate` (max concurrent connections) gating traffic before handlers run.
- Lifecycle awareness: `keepDeviceAwake`, `bindToLifecycle()` (stop on background / restart on `.active`), `requestSingleAppMode()` for kiosk/Autonomous Single App Mode.
- TLS via `useHttps(p12:passwordKeychainKey:)`, secrets (JWT keys, `.p12` passwords) always from the Keychain via `SecretStore`, never from JSON.
- Configuration via `appsettings.json`/`appsettings.Development.json`, environment-aware (`.development`/`.production`), Bonjour discovery (`advertise(name:)`), dependency injection (`builder.services`).
- Web hosting: zero-build Vue 3 (`app.useVue()`, bundled SPM resource, no build step) or full Vite + `.vue` workflow; `useStaticFiles`/`useSpa` with `ETag`/`Range`/precompressed-sidecar support; `[[ ]]`-delimited server-side template engine that stays out of Vue's `{{ }}` syntax.
- Realtime: `mapSse` and `mapWebSocket`.
- API docs: `mapOpenApi(...)` serving `/openapi.json` from compile-time route metadata, schemas via `@ApiModel` (no reflection).
- `ServerMetrics`: in-memory counters and a fixed-size ring of recent requests — total/req-per-second, latency (mean/p50/p95/max), status-class breakdown, rate-limit/connection-cap rejections, active connections, active WebSockets, byte throughput, rebind count, uptime.
- `SwiftCoreWebTesting.TestHost`: runs the exact same handler chain as production (routing, middleware, auth, handlers) over an in-memory `NIOAsyncTestingChannel`, with `get`/`post`/`put`/`patch`/`delete`/`head`/`options` helpers and `TestResponse.decode`/`bodyString`.

### Added — `SwiftCoreWebDashboard` (opt-in, separate target)
- On-device SwiftUI console replacing the app's screen with a live view of the server: Mission Control (dense NOC-style) and Native Cards (iOS-native look) styles, switchable at runtime and persisted, no rebuild needed.
- Device metrics sampler (1 Hz, public APIs only): CPU (system + per-process), memory footprint, `ProcessInfo.thermalState`, battery level/state and Low Power Mode, storage free/total, network path/interface/throughput, system and app uptime.
- SQLite-backed history (system `libsqlite3`, no SPM dependency) with 24h-per-minute / 7d-per-hour / 30d-per-day retention and automatic rollup/pruning.
- QR code of the server's LAN URL, Start/Stop/Restart controls, live request log.
- Opt-in `mapMetrics(_:)` HTTP endpoint (JSON) plus an SSE stream, off by default.
- Explicit about what iOS does *not* expose publicly (CPU/battery °C, GPU %, Wi-Fi SSID) rather than simulating it.

### Added — showcase & docs
- `HelloWorldApp` showcase demonstrating the dashboard as the app's default on-device screen, with `/` still serving `www/index.html` to browsers.
- README course-style walkthrough for the dashboard, App Store review notes (Info.plist keys, local-network prompt, what to protect), .NET-to-SwiftCoreWeb naming table.
- Side-by-side dashboard style screenshots (`docs/screenshots/`).

### Security & compliance
- No hardcoded credentials anywhere in the package: JWT signing keys and `.p12` passwords are Keychain-only via `SecretStore`.
- `useSecurityHeaders()` and `useAuthentication`/`useAuthorization` middleware built into the core pipeline.
- `RateLimiter` and `ConnectionGate` protect against request floods and connection exhaustion by default.
- Personal data handling: dashboard history stores only aggregates, never client IPs or request paths; `ServerMetrics`' recent-request ring (IPs included) stays in memory only, never persisted.
- `mapMetrics` documented as requiring `auth:` on untrusted LANs.
- Legal/security scaffolding: `LICENSE` (PolyForm Noncommercial 1.0.0), `LICENSE-THIRD-PARTY`, `CLA.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`.
- CI: build/test workflow, Dependabot (Swift + GitHub Actions ecosystems), gitleaks secret scanning on every push/PR, OpenSSF Scorecard, CLA Assistant bot.
- Internal-only git-publishing toolchain (`scripts/publish-github.sh`, `.githooks/pre-push`) keeps local planning docs and the toolchain itself out of the public GitHub history.
