# SwiftCoreWeb

[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE)
[![Swift](https://img.shields.io/badge/swift-6-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-lightgrey)](README.md#requirements)
[![SwiftNIO](https://img.shields.io/badge/SwiftNIO-2.65-blue)](https://github.com/apple/swift-nio)
[![Vue](https://img.shields.io/badge/Vue-3-brightgreen?logo=vuedotjs)](https://vuejs.org)
[![SQLite](https://img.shields.io/badge/SQLite-3-lightblue?logo=sqlite)](https://sqlite.org)
[![Security Policy](https://img.shields.io/badge/security-policy-orange)](SECURITY.md)
[![Contributing](https://img.shields.io/badge/contributing-guide-informational)](CONTRIBUTING.md)
[![Donate with PayPal](https://img.shields.io/badge/PayPal-donate-blue?logo=paypal)](https://paypal.me/prioregroup)
[![Donate with BITCOIN](https://img.shields.io/badge/BITCOIN-donate-green?logo=bitcoin)](https://github.com/priore/SwiftCoreWeb#support-development)
[![Star History](https://img.shields.io/badge/⭐-Star%20History-blue)](https://star-history.com/#priore/SwiftCoreWeb&Date)

Your iPhone can run a real web server. SwiftCoreWeb turns any iOS 15+ app into a full HTTP/HTTPS/WebSocket backend, no separate server needed. Same fluent, Minimal-API feel .NET developers already love, done in idiomatic Swift, with **zero runtime reflection**.

---

## Requirements

- iOS 15.0+ deployment target
- Xcode 16+ / Swift 6 language mode (macros require a Swift 5.9+ toolchain at compile time only — zero runtime cost)
- Dependencies: `swift-nio`, `swift-nio-transport-services`, `swift-syntax` (macros only). Everything else — TLS, JWT signing/verification, logging, network monitoring — uses system frameworks (`Security`, `CryptoKit`, `os.Logger`, `Network`).

## Hello World

```swift
import SwiftCoreWeb

let app = WebApplication.createBuilder().build()
app.mapGet("/hello") { "Hello, world!" }
try await app.runAsync()
```

Binds to `127.0.0.1:8080` by default — secure by default, no LAN exposure until you explicitly opt in with `builder.listenOnAllInterfaces()`.

---

## Core concepts

### Configuration & environment

`WebApplication.createBuilder()` returns a `WebApplicationBuilder`. Use it to configure:

- Ports and binding: `usePort`, `useHost`, `listenOnAllInterfaces`
- TLS: `useHttps(p12:passwordKeychainKey:)`
- Limits: `maxRequestBodySize`, `requestTimeout`, `maxConcurrentConnections`, `maxHeaderSize`
- Rate limiting: `rateLimit { ... }`
- Bonjour discovery: `advertise(name:)`
- Keep-awake: `keepDeviceAwake`
- Dependency injection: `builder.services`

`builder.environment` defaults to `.development` in `DEBUG` builds and `.production` otherwise. Dev-only features — the `/__routes` list, live reload, detailed error bodies — only activate in `.development`.

Optional `appsettings.json` / `appsettings.Development.json` files in the bundle populate the typed options above. Secrets (JWT keys, `.p12` passwords) always come from the Keychain via `SecretStore`, never from JSON.

### App Store review notes

Plain-language summary: running a server on the device is not, by itself, a reason Apple rejects an app. What gets an app rejected is a missing permission prompt, or personal data left unprotected on the network.

- **Default binding (`127.0.0.1`) needs nothing extra.** Nothing leaves the device, so there's no permission prompt and no Info.plist key to add.
- **`listenOnAllInterfaces()` or `advertise(name:)` put the app on the Wi-Fi network**, which means iOS shows the person a one-time "Allow this app to find devices on your local network?" prompt. Two `Info.plist` keys are required for that prompt to work — add them in the *app* that links this package (a library can't add Info.plist keys for you):

  ```xml
  <key>NSLocalNetworkUsageDescription</key>
  <string>This app runs a local web server so you can view its content from a browser on the same Wi-Fi network.</string>
  <key>NSBonjourServices</key>
  <array>
      <string>_http._tcp</string>
  </array>
  ```

  `NSLocalNetworkUsageDescription` is the sentence shown in that permission popup — write it in plain words the person will actually understand, in the app's own language (the text above is just a generic starting point, adapt it to what the app really does). `NSBonjourServices` is the technical service name (`_http._tcp`, HTTP over TCP) this package advertises with `advertise(name:)`; if it's missing, advertising just fails silently instead of showing the prompt, and a reviewer testing that feature will see it not working.
  - Skip these two keys entirely if the app never calls `listenOnAllInterfaces()` or `advertise(name:)`.
- **Protect what the server exposes.** A server reachable from other devices on the Wi-Fi is a normal thing to ship, but anything personal it serves (device battery/health data via `mapMetrics`, for example) should require login (`auth:`) unless the network is fully trusted. And when submitting to App Review, add a short note explaining why the app runs a server (**) — reviewers who don't get that context sometimes reject just for clarification, not because anything is actually wrong. Example, in the App Review "Notes" field:

> ** e.g.: This app runs a local HTTP server so the user's other devices on the same Wi-Fi network can view (describe what: e.g. "the photos in this album", "the exported report", "the device's live dashboard"). The server only responds to devices on the same local network — it never uploads data anywhere else. No login is required to view (content) because (reason, e.g. "it contains no personal data" — or, if it does, name the auth: it requires instead).

### Routing

One router, two styles, pick per route:

- **Minimal API closures**
  - `app.mapGet`, `mapPost`, `mapPut`, `mapPatch`, `mapDelete`, `mapHead`, `mapOptions`, `mapMethods([...], ...)`
  - grouped with `app.mapGroup("/api").requireAuthorization()`
- **Macro-based controllers**
  - `@Controller("/prefix")` on a `final class`/`struct`/`actor`
  - `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route` mark each handler method
  - `@Controller` generates `registerRoutes(into:)` at compile time
  - registration stays explicit via `app.mapControllers(UserController.self, OrderController.self)` — zero runtime type discovery

Route templates:

- typed constraints: `{id:int}`, `{id:uuid}`
- optional segments: `{page?}`
- catch-alls: `{*path}`
- `HEAD` served automatically for every `GET` route
- `OPTIONS` answered automatically with an `Allow` header
- a path match with no method match returns `405`

Handler parameters bind automatically, in this order:

1. An `HttpContext` parameter is injected.
2. A name matching a route placeholder binds from the path.
3. A non-primitive `Decodable` on `POST`/`PUT`/`PATCH` binds from the JSON body.
4. A primitive or optional primitive binds from the query string.
5. `Header<T>`, `Query<T>`, `Service<T>`, and `Form` give explicit control when the convention isn't enough.

Any conversion failure produces a `400` `ProblemDetails` naming the offending parameter.

The macro compiler plugin also catches mistakes before you run anything, with compile-time diagnostics and Fix-Its where possible — a clear compiler error, never a runtime surprise:

- a placeholder with no matching parameter (and vice versa)
- an unsupported parameter or return type
- a duplicate method+path
- a marker used outside `@Controller`
- a non-`Sendable` controller
- invalid route syntax

### Middleware

A sequential async pipeline, `IApplicationBuilder`-style: `app.use { ctx, next in ...; try await next() }`, or a reusable `Middleware` conformance. Middleware runs in registration order.

Built-ins:

- `.useExceptionHandler()` — always first; turns any thrown error into an RFC 9457 ProblemDetails response
- `.useCors(_:)`
- `.useSecurityHeaders()`
- `.useAuthentication(_:)` — pluggable schemes; JWT is just the built-in default, alongside Basic and fully custom schemes
- `.useAuthorization(policies:)`
- `.useStaticFiles(root:)`
- `.useRequestLogging()`

### Server engine & lifecycle

A single `NIOTSListenerBootstrap` (Network.framework via `NIOTransportServices`) serves both HTTP and, when `.useHttps(...)` is configured, HTTPS on the same pipeline — no second transport stack to manage.

NIO is bridged to Swift Concurrency with `NIOAsyncChannel`, so handler code is plain `async throws`, never `EventLoopFuture`. Before any request reaches your handlers, a `RateLimiter` actor gates traffic and a `ConnectionGate` caps concurrent connections.

Lifecycle is app-state aware:

- `builder.keepDeviceAwake(true)` (the default) disables the idle timer while serving in the foreground
- `app.bindToLifecycle()` gracefully stops the server on background and restarts it on `.active` (the showcase shows the SwiftUI `ScenePhase`-driven version of this)
- `app.requestSingleAppMode()` wraps Autonomous Single App Mode, for kiosk deployments on a supervised device

### Web hosting & Vue

Two ways to ship a frontend:

- **Zero-build**: Vue 3 ships as a bundled SPM resource. `app.useVue()` serves it at `/_framework/vue.js`, fully offline, no build step.
- **Full workflow**: the standard Vite + `.vue` setup, for larger apps.

Either way you get `app.useStaticFiles(root:)` and `app.useSpa(root:)` for static assets and SPA history-mode fallback, with `ETag`/`Range`/precompressed-sidecar support. A `[[ ]]`-delimited server-side template engine (`View("page.html", model:)`, `injectState(_:)`) stays out of Vue's own `{{ }}` syntax, so the two never collide.

- Realtime: `app.mapSse(_:_:)` and `app.mapWebSocket(_:_:)`
- API docs: `app.mapOpenApi(...)` serves `/openapi.json` built from compile-time route metadata, with schemas generated by `@ApiModel`

### Testing

`SwiftCoreWebTesting.TestHost` runs the exact same handler chain as production — the same `RequestDispatcher` handling routing, middleware, auth, and handlers — just driven through an in-memory `NIOAsyncTestingChannel` instead of a bound socket:

```swift
import SwiftCoreWeb
import SwiftCoreWebTesting

let app = WebApplication.createBuilder().build()
app.mapGet("/api/users/{id:int}") { ctx in
    User(id: try bindRouteValue(ctx.request.routeValues["id"], as: Int.self, parameterName: "id"))
}

let host = try await TestHost(app)
let res = try await host.get("/api/users/1")
let user = try res.decode(User.self)
```

`get`/`post`/`put`/`patch`/`delete`/`head`/`options` helpers cover every HTTP method, with headers, a raw or JSON-encoded body, and `TestResponse.decode(_:)`/`bodyString` for assertions.

---

## Showcase

`Showcase/` is a complete, real end-to-end sample app — not a toy. It compiles against the actual API, and includes:

- A SwiftUI app whose device screen shows the on-device dashboard (see below) while `/` keeps serving the site to browsers
- A macro-based `@Controller` alongside closure Minimal API routes, on the same server
- Two authentication schemes: JWT and a custom API-key header
- SwiftUI `ScenePhase` lifecycle binding, plus keep-awake

It also walks through the three frontend workflows you'll actually use, and ships ready-to-copy `Info.plist` keys, `vite.config.js`, and both scripts:

- Vite on the Mac with API proxying
- on-device dev-deploy with live reload
- a production Xcode build phase that copies `dist/` into the bundle

See `Showcase/README.md` for the full walkthrough and how to wire the sample into an Xcode project. It ships as source files, not an `.xcodeproj`, since the framework itself is SPM-only.

---

## On-device dashboard (`SwiftCoreWebDashboard`)

Turns the device's own screen into a live console for the server running on it — request rate, latency, CPU/memory/battery/thermal state, connection log — instead of (or alongside) whatever your app would otherwise show.

- Separate library target, opt-in: the core `SwiftCoreWeb` package has no SwiftUI in it
- `/` keeps serving `www/index.html` to browsers exactly as before
- not a build-time choice either — the visual style switches at runtime and the choice is remembered

Read this section top to bottom the first time; it's laid out as a short course, each part builds on the last. Skip to a lesson once you know what you're after.

**Index**
1. [Add the dependency](#1-add-the-dependency)
2. [Minimal setup — one line](#2-minimal-setup--one-line)
3. [Picking a look: Mission Control vs Native Cards](#3-picking-a-look-mission-control-vs-native-cards)
4. [Configuring history retention](#4-configuring-history-retention)
5. [Driving the model yourself (custom UI, tests, shared state)](#5-driving-the-model-yourself-custom-ui-tests-shared-state)
6. [Opt-in HTTP metrics endpoint](#6-opt-in-http-metrics-endpoint)
7. [The web side keeps working: serving pages alongside the dashboard](#7-the-web-side-keeps-working-serving-pages-alongside-the-dashboard)
8. [What's not there, on purpose](#8-whats-not-there-on-purpose)

### 1. Add the dependency

```swift
// Package.swift
.target(
    name: "YourApp",
    dependencies: [
        "SwiftCoreWeb",
        "SwiftCoreWebDashboard", // adds SwiftUI + system libsqlite3, nothing else
    ]
)
```

### 2. Minimal setup — one line

The whole point: your app already builds a `WebApplication`. Hand it to the dashboard view instead of building your own screen.

```swift
import SwiftUI
import SwiftCoreWeb
import SwiftCoreWebDashboard

struct RootView: View {
    let app: WebApplication // however you already build/hold it

    var body: some View {
        SwiftCoreWebDashboardView(app: app)
    }
}
```

That's it. This one line: opens (or creates) the on-disk metrics history, samples device health at 1 Hz, and shows whichever style (Mission Control / Native Cards) the user last picked — default `nativeCards` on first launch. No further config needed to see it working.

### 3. Picking a look: Mission Control vs Native Cards

Both styles ship built-in; a segmented control in the dashboard itself lets the person using the device switch between them at runtime, no relaunch.

| Mission Control | Native Cards |
|:---:|:---:|
| ![Mission Control style](docs/screenshots/dashboard-mission-control.png) | ![Native Cards style](docs/screenshots/dashboard-native-cards.png) |

You don't choose one in code — but you can read or force the stored choice, e.g. to default kiosk hardware to the dense NOC-style view:

```swift
import SwiftCoreWebDashboard

// Read what's currently picked (persisted in UserDefaults):
let current = DashboardStyle.stored // .missionControl or .nativeCards

// Force a default before the dashboard ever appears — useful for a kiosk
// build that always wants the dense, wall-readable style:
DashboardStyle.stored = .missionControl
```

`DashboardStyle.stored` is just a `UserDefaults`-backed property — setting it before `SwiftCoreWebDashboardView` appears changes what the person sees on first launch; they can still switch it from the UI afterwards.

### 4. Configuring history retention

Default retention is 24h at 1-minute resolution, 7 days hourly, 30 days daily (bounds the on-disk SQLite file to roughly 1440+168+30 rows). Pass a `DashboardConfiguration` if your app needs shorter/longer windows — e.g. a demo unit that only needs a few hours of history:

```swift
import SwiftCoreWebDashboard

let shortHistory = DashboardConfiguration(
    minuteRetentionSeconds: 2 * 3600,   // 2h of minute-level history…
    hourRetentionSeconds: 24 * 3600,    // …1 day hourly…
    dayRetentionSeconds: 7 * 24 * 3600  // …1 week daily
)

SwiftCoreWebDashboardView(app: app, configuration: shortHistory)
```

### 5. Driving the model yourself (custom UI, tests, shared state)

`SwiftCoreWebDashboardView` owns its `DashboardModel` privately — fine for "just show the dashboard", not enough if you need to inject a fake history for a test, or show the same live data in a second view. Build the model yourself and use `DashboardRootView` instead:

```swift
import SwiftUI
import SwiftCoreWeb
import SwiftCoreWebDashboard

@MainActor
struct CustomDashboardHost: View {
    @State private var model: DashboardModel?
    let app: WebApplication

    var body: some View {
        Group {
            if let model {
                DashboardRootView(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            // withDefaultHistory opens the real on-disk SQLite store;
            // pass `history: nil` (via `DashboardModel(app:history:)`) in a
            // test target instead, and the dashboard runs live-only, no crash.
            let model = await DashboardModel.withDefaultHistory(app: app)
            model.startSampling()
            self.model = model
        }
    }
}
```

`model.latestServer` / `model.latestDevice` are `@Published` — read them directly if you're building your own tile instead of using the shipped views.

### 6. Opt-in HTTP metrics endpoint

Everything above stays on the device screen. If you also want the same numbers reachable over HTTP (e.g. for your own monitoring, or a second device polling this one), opt in explicitly — it's never registered unless you call it:

```swift
import SwiftCoreWeb
import SwiftCoreWebDashboard

// JSON at GET /_metrics, Server-Sent Events at GET /_metrics/stream
app.mapMetrics("/_metrics", model: dashboardModel)
```

This exposes device health (battery level, thermal state, memory footprint…) to anyone who can reach the route — protect it the same way you'd protect any other route on an untrusted LAN:

```swift
app.mapMetrics("/_metrics", model: dashboardModel, auth: .authenticated)
// or: auth: .roles(["admin"]), auth: .scheme("apiKey"), auth: .policy("adminOnly")
```

The payload never includes per-request client IPs — those stay in memory only, never serialized or persisted (see the privacy note below).

### 7. The web side keeps working: serving pages alongside the dashboard

The dashboard only replaces what's on the *device's own screen*. `/` and every other route you map still serve real pages to whoever hits the server from a browser — the dashboard doesn't own routing. Four different ways to serve a page, from simplest to most involved:

**a) One static file, no build step**

```swift
app.useStaticFiles(root: .bundle("www")) // serves everything under www/ as-is
// GET /index.html -> www/index.html, GET /style.css -> www/style.css, etc.
```

**b) A single-page app (Vue/React/whatever), history-mode routing**

```swift
app.useStaticFiles(root: .bundle("www"))
app.useSpa(root: .bundle("www")) // any unmatched non-/api route -> www/index.html
```

`apiPrefix` defaults to `/api`, so `app.mapGet("/api/users", ...)` still resolves as an API route instead of falling back to the SPA's `index.html`.

**c) Zero-build Vue, no separate frontend build at all**

```swift
app.useVue()                     // serves the bundled Vue 3 runtime at /_framework/vue.js
app.useStaticFiles(root: .bundle("www")) // your own www/index.html <script>-tags it in
```

**d) Server-rendered HTML with a model, no client-side framework — two pages, linked, each with its own variables**

Register the view root once, then return `View(_:model:)` from as many routes as you like; each gets its own model type.

```swift
app.useViews(root: .bundle("www")) // once, before any View(...) is returned

struct HomeModel: Encodable {
    let deviceName: String
    let requestCount: Int
}

struct DeviceDetailModel: Encodable {
    let deviceName: String
    let systemVersion: String
    let batteryPercent: Int
}

app.mapGet("/") { _ in
    View("index.html", model: HomeModel(
        deviceName: UIDevice.current.name,
        requestCount: app.metrics.snapshot().totalRequests
    ))
}

app.mapGet("/device") { _ in
    View("device.html", model: DeviceDetailModel(
        deviceName: UIDevice.current.name,
        systemVersion: UIDevice.current.systemVersion,
        batteryPercent: Int(UIDevice.current.batteryLevel * 100)
    ))
}
```

`www/index.html` — links to the second page, no query string needed since `/device` reads its own model server-side:

```html
<!doctype html>
<html>
  <body>
    <h1>[[ deviceName ]]</h1>
    <p>Requests served: [[ requestCount ]]</p>
    <a href="/device">Device details</a>
  </body>
</html>
```

`www/device.html` — a different template, different model, navigated to by the link above:

```html
<!doctype html>
<html>
  <body>
    <h1>[[ deviceName ]]</h1>
    <p>iOS [[ systemVersion ]] — battery [[ batteryPercent ]]%</p>
    <a href="/">&larr; Back</a>
  </body>
</html>
```

Every `[[ name ]]` is looked up in that route's own model and HTML-escaped automatically; `[[& name ]]` skips escaping for a value you already know is safe markup. `[[ ]]`-delimited on purpose, so it never collides with Vue's own `{{ }}` syntax if the same page also loads Vue. See [Web hosting & Vue](#web-hosting--vue) above for `injectState(_:)` (hydrating client-side JS with the same model) and realtime routes (`mapSse`, `mapWebSocket`).

Any of the four can run at the same time as the dashboard — the device screen and the HTTP server are two independent outputs of the same `WebApplication`.

### 8. What's not there, on purpose

- **No CPU/battery temperature in °C, no fan %, no GPU %, no Wi-Fi SSID.** iOS has no public API for these; the dashboard shows `ProcessInfo.thermalState` (nominal/fair/serious/critical) instead of a fake number, and never simulates data.
- **No client IPs or request paths on disk.** The SQLite history stores only aggregates (CPU/mem/latency/request counts); the live 5-minute ring (in memory only) is where per-request detail lives, and it's gone on relaunch.
- **No Swift Charts.** Deployment target is iOS 15; sparklines and gauges are custom `SwiftUI.Path`/`Shape`, so there's no iOS 16 floor just for a chart.

---

## .NET-to-SwiftCoreWeb naming table

For developers coming from ASP.NET Core Minimal APIs, here is how the familiar surface maps onto SwiftCoreWeb's idiomatic-Swift camelCase API.

| ASP.NET Core / .NET | SwiftCoreWeb |
|---|---|
| `WebApplication.CreateBuilder()` | `WebApplication.createBuilder()` |
| `builder.Build()` | `builder.build()` |
| `app.Run()` / `app.RunAsync()` | `try await app.runAsync()` |
| `app.StopAsync()` | `try await app.stopAsync(timeout:)` |
| `app.Urls` | `app.urls` |
| `app.MapGet("/x", handler)` | `app.mapGet("/x") { ctx in ... }` |
| `app.MapPost`/`MapPut`/`MapPatch`/`MapDelete` | `app.mapPost`/`mapPut`/<br>`mapPatch`/`mapDelete` |
| `app.MapGroup("/api")` | `app.mapGroup("/api")` |
| `RequireAuthorization()` | `.requireAuthorization(_:)` |
| `[ApiController]` + `[Route]` | `@Controller(_ prefix:)` |
| `[HttpGet]`/`[HttpPost]`/etc. | `@Get`/`@Post`/`@Put`/`@Patch`/<br>`@Delete`/`@Head`/`@Options`/`@Route` |
| Route constraints (`{id:int}`) | Route constraints:<br>`{id:int}`, `{id:uuid}`, `{page?}`, `{*path}` |
| `IApplicationBuilder.Use(...)` | `app.use { ctx, next in ... }` |
| `IMiddleware` | `Middleware` protocol |
| `app.UseExceptionHandler()` | `app.useExceptionHandler()` |
| `app.UseCors(...)` | `app.useCors { ... }` |
| `app.UseAuthentication()` | `app.useAuthentication(_:)` |
| `app.UseAuthorization()` | `app.useAuthorization(policies:)` |
| `app.UseStaticFiles()` | `app.useStaticFiles(root:)` |
| `[Authorize]` | `auth: .authenticated` / `.roles([...])` / `.policy(...)` / `.scheme(...)` |
| `HttpContext` | `HttpContext` |
| `HttpContext.Request` | `ctx.request` (`HttpRequest`) |
| `HttpContext.Response` | `ctx.response` (`HttpResponse`) |
| `HttpContext.User` (`ClaimsPrincipal`) | `ctx.user` (`ClaimsPrincipal?`) |
| `HttpContext.Items` | `ctx.items` |
| `IResult` / `Results.Ok(...)` | `HttpResult` / `Results.ok(_:)` |
| `Results.Created`/`NoContent`/`BadRequest`/<br>`NotFound`/`Unauthorized`/`Forbid`/`Redirect`/`File`/`Stream` | `Results.created`/`noContent`/`badRequest`/<br>`notFound`/`unauthorized`/`forbidden`/`redirect`/`file`/`stream` |
| `ProblemDetails` | `ProblemDetails` (RFC 9457) |
| Custom exception → status code | `throw HttpError(_:_:)` |
| `IServiceCollection.AddSingleton`/`AddTransient` | `builder.services.addSingleton`/`addTransient` |
| `IServiceProvider.GetRequiredService<T>()` | `ctx.services.get(T.self)` |
| `[FromRoute]`/`[FromQuery]`/`[FromHeader]`/<br>`[FromServices]`/`[FromBody]`/`[FromForm]` | Convention-based binding by name/type,<br>or `Header<T>`/`Query<T>`/`Service<T>`/`Form` |
| `appsettings.json` / `appsettings.{Environment}.json` | `appsettings.json` / `appsettings.Development.json` |
| `IHostEnvironment.EnvironmentName` | `builder.environment` (`.development` / `.production`) |
| `IConfiguration` typed options | Typed `Codable` options:<br>`ServerOptions`, `CorsOptions`, `RateLimitOptions`, `AuthOptions` |
| ASP.NET Core rate limiting middleware | `builder.rateLimit { ... }`<br>(token-bucket, pre-pipeline) |
| Kestrel | The single NIOTransportServices-backed `ServerEngine` |
| `app.UseWebSockets()` + a handler | `app.mapWebSocket(_:_:)` |
| Server-Sent Events (manual) | `app.mapSse(_:_:)` (`SseWriter`/`SseEvent`) |
| Swashbuckle / `AddOpenApi()` | `app.mapOpenApi(title:version:models:)`<br>(`/openapi.json`) |
| A DTO's OpenAPI schema (reflection-based) | `@ApiModel` (compile-time, no reflection) |
| Razor Pages / views | `View("page.html", model:)`<br>+ the `[[ ]]`-delimited template engine |
| `TestServer` / `WebApplicationFactory` | `SwiftCoreWebTesting.TestHost` |

---

## Support Development

If this project has been useful to you, consider a small donation. Every contribution helps fund new features and keep the project active.

Scan the code below with your wallet, or copy the address. Alternatively you can donate via [PayPal](https://paypal.me/prioregroup).

|Donate with BTC (Bitcoin)|
|:------------:|
|![](https://www.prioregroup.com/images/priore_btc_segwit_binance.jpg)|
|`BTC Address (SegWit) : bc1q6rjOuuwu9k2fvs5n5elmqy9v4ljazhexejykjm`|

---

## License

SwiftCoreWeb is licensed under the **[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)**.

- **Free for noncommercial use.** Personal projects, education, research, and evaluation are all fine at no cost.
- **Commercial use requires a separate license from the author.** If your use case makes or supports revenue, get in touch before shipping it.
- The source is publicly readable on GitHub, but this is **not** an OSI-approved open-source license. SwiftCoreWeb is **source-available**, not open-source — please don't call it open-source in code, docs, or conversation.

The full license text is in `LICENSE` at the repository root. Third-party components embedded in this package (the Vue 3 runtime, SwiftNIO, swift-nio-transport-services) keep their own upstream licenses and required notices — see `LICENSE-THIRD-PARTY`.

Want to contribute? Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Found a security issue? See [SECURITY.md](SECURITY.md), don't open a public issue.
