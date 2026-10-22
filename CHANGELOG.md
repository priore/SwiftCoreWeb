# Changelog

All notable changes to this project are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **Binary responses with a file name.**
  - `Results.data(_:contentType:fileName:disposition:)` sends in-memory bytes.
  - `Results.file` and `Results.stream` take `fileName:` and `disposition:` (`.attachment` or `.inline`).
  - `Content-Disposition` carries a quoted ASCII `filename` fallback plus a percent-encoded `filename*=UTF-8''…` (RFC 6266/5987).
  - Quotes, CR/LF, control characters and path separators in the name are neutralised, so any string is safe.
  - `Results.stream(contentLength:)` sends `Content-Length` instead of chunked encoding.
- **`Range`, `If-Range` and `HEAD` work for any `Results.file`.**
  - Previously only the static file middleware answered `206`; the dispatcher now resolves them for every handler.
  - A start past the end answers `416` with `Content-Range: bytes */size`.
- **`Form` parameters bind `application/x-www-form-urlencoded` bodies.**
  - Text fields only, no files.
  - Works in addition to `multipart/form-data`.
- **Per-route request body limit without a group.**
  - `mapPost`, `mapPut`, `mapPatch`, `mapDelete` and `mapMethods` take `maxRequestBodySize:`.
  - `@Post`, `@Put`, `@Patch` and `@Delete` take `maxRequestBodySize:` too.
  - `RouteRegistry` gained a `register(…, maxBodySize:…)` requirement with a default that ignores the limit.
- **`UploadedFile.move(to:)` and `UploadedFile.data()`.**
  - `move(to:)` replaces an existing destination and survives the post-response temporary file cleanup.
- **Per-route request body limit.**
  - `app.mapGroup("/files").maxRequestBodySize(_:)` overrides the global limit for the routes of that group (and nested groups).
  - The server engine resolves it from the request head, before buffering the body.
  - The dispatcher enforces the same limits, so `TestHost` answers `413` exactly like a real socket.
- **Live Pages file upload and download.**
  - `<input type="file" @change="$swiftUpload('evt', $event, { multiple, accept })">` posts `multipart/form-data` to the page path; handlers read `ctx.files`.
  - The multipart event is verified like a JSON event (signed snapshot, path, antiforgery) and also requires the `X-SCW-Live: 1` header set by `live.js`.
  - `Page.maxUploadBytes`, `allowedUploadTypes` and `maxUploadFiles` limit uploads (`413` or `ctx.errors["files"]`); `maxUploadBytes` also sets the route's body limit.
  - `PageAction.download(data:)`, `download(filePath:)` and `download(stream:)` reply with a one-time `/_framework/dl/<token>` URL that `live.js` navigates to; no `blob:` URLs.
  - A `.result(...)` from `onEvent` is converted on the server (redirect, re-render or download); `live.js` no longer parses a response without a `snapshot`.
  - `$live.busy` is set while an upload is in flight.
- **`app.useBlobDownloads(maxBytes:injection:)`: `blob:` downloads for unmodified web code inside `WKWebView`.**
  - Independent of Vue, Pages, sessions and SPA hosting; works in an API-only app.
  - `POST /_framework/blob` stores the uploaded bytes and returns a one-time `GET /_framework/dl/<token>` attachment URL, bound to the antiforgery (and session) cookie, bounded and in memory only.
  - `GET /_framework/blob-download.js` serves the client shim, also exposed as `BlobDownloadShim.source`.
  - `BlobShimInjection` (`.auto`, `.always`, `.never`) controls an optional middleware that adds the shim tag to HTML responses from any source; `.auto` only for `User-Agent`s containing `SwiftCoreWebHost/1`.
- **`SwiftCoreWebKit` library product (optional, imports WebKit).**
  - `BlobDownloadSupport` is a plain object your own `WKNavigationDelegate` forwards to; it is also the `WKDownloadDelegate`.
  - `install(on:)` sets the user-agent token and adds the shim as a user script.
- **Docs.** New [Blob downloads in WKWebView](docs/web/BLOB_DOWNLOADS.md); download, upload and per-route limit examples in the API basic examples; upload and download in the Live Pages guide.

### Changed
- **An over-limit request now gets its `413` reliably.**
  - The engine answers with `Connection: close`, then reads and discards the rest of the request (at most 64 MB, 5 s) before closing; before, closing while the client was still sending made it see a connection reset.
  - The same applies to the `429` of the rate limiter.
- **`TestHost` enforces the request body limit** (`413` above `maxRequestBodySize` or the route group's limit), as the server engine always did.
  - A test that posts more than 1 MB now needs the limit raised on the builder or the route group.
- **An unsatisfiable `Range` on a static file now answers `416`** instead of falling back to the full body (RFC 9110).
- **`live.js` and `api.js`** gained multipart/`FormData` support and a guard against responses that are not page JSON; both are served with immutable caching, so a browser that cached the old files needs a hard reload.
- **`bindForm(_ ctx:)` accumulates** the temporary files of several calls on one request instead of replacing the list.

### Deprecated
- **`bindForm(_ request: HttpRequest)`**: use `bindForm(_ ctx: HttpContext)`, which the macros now generate.
  - The deprecated form leaves the uploaded temporary files for the caller to delete.

### Fixed
- **`Form` parameters were always empty.**
  - `multipart/form-data` bodies are now parsed into `fields` and `files`.
  - Uploaded files are written to temporary files named by a UUID, never by the client's filename.
  - The temporary files are deleted after the response.
  - A body that is not valid multipart, or has any other `Content-Type`, answers `400`.
- **Dev deploy (`useDevDeploy`) upload handling.**
  - No longer writes outside its temporary directory when an uploaded filename contains `..` or is absolute.
  - No longer truncates a file that contains the multipart boundary string.
  - Now shares the multipart parser used by `Form`.

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
