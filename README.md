# SwiftCoreWeb

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

### Routing

One router, two styles, pick per route:

- **Minimal API closures**: `app.mapGet`, `mapPost`, `mapPut`, `mapPatch`, `mapDelete`, `mapHead`, `mapOptions`, `mapMethods([...], ...)`, grouped with `app.mapGroup("/api").requireAuthorization()`.
- **Macro-based controllers**: `@Controller("/prefix")` on a `final class`/`struct`/`actor`, with `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route` marking each handler method. `@Controller` generates `registerRoutes(into:)` at compile time. Registration stays explicit via `app.mapControllers(UserController.self, OrderController.self)` — zero runtime type discovery.

Route templates support typed constraints (`{id:int}`, `{id:uuid}`), optional segments (`{page?}`), and catch-alls (`{*path}`). `HEAD` is served automatically for every `GET` route, `OPTIONS` is answered automatically with an `Allow` header, and a path match with no method match returns `405`.

Handler parameters bind automatically, in this order:

1. An `HttpContext` parameter is injected.
2. A name matching a route placeholder binds from the path.
3. A non-primitive `Decodable` on `POST`/`PUT`/`PATCH` binds from the JSON body.
4. A primitive or optional primitive binds from the query string.
5. `Header<T>`, `Query<T>`, `Service<T>`, and `Form` give explicit control when the convention isn't enough.

Any conversion failure produces a `400` `ProblemDetails` naming the offending parameter.

The macro compiler plugin also catches mistakes before you run anything — a placeholder with no matching parameter (and vice versa), an unsupported parameter or return type, a duplicate method+path, a marker used outside `@Controller`, a non-`Sendable` controller, invalid route syntax — with compile-time diagnostics and Fix-Its where possible. You get a clear compiler error, never a runtime surprise.

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

Lifecycle is app-state aware: `builder.keepDeviceAwake(true)` (the default) disables the idle timer while serving in the foreground, and `app.bindToLifecycle()` gracefully stops the server on background and restarts it on `.active` (the showcase shows the SwiftUI `ScenePhase`-driven version of this). For kiosk deployments on a supervised device, `app.requestSingleAppMode()` wraps Autonomous Single App Mode.

### Web hosting & Vue

Two ways to ship a frontend:

- **Zero-build**: Vue 3 ships as a bundled SPM resource. `app.useVue()` serves it at `/_framework/vue.js`, fully offline, no build step.
- **Full workflow**: the standard Vite + `.vue` setup, for larger apps.

Either way you get `app.useStaticFiles(root:)` and `app.useSpa(root:)` for static assets and SPA history-mode fallback, with `ETag`/`Range`/precompressed-sidecar support. A `[[ ]]`-delimited server-side template engine (`View("page.html", model:)`, `injectState(_:)`) stays out of Vue's own `{{ }}` syntax, so the two never collide.

For realtime, use `app.mapSse(_:_:)` and `app.mapWebSocket(_:_:)`. For API docs, `app.mapOpenApi(...)` serves `/openapi.json` built from compile-time route metadata, with schemas generated by `@ApiModel`.

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

- A SwiftUI app hosting the served site in a `WKWebView`
- A macro-based `@Controller` alongside closure Minimal API routes, on the same server
- Two authentication schemes: JWT and a custom API-key header
- SwiftUI `ScenePhase` lifecycle binding, plus keep-awake

It also walks through the three frontend workflows you'll actually use — Vite on the Mac with API proxying, on-device dev-deploy with live reload, and a production Xcode build phase that copies `dist/` into the bundle — and ships ready-to-copy `Info.plist` keys, `vite.config.js`, and both scripts.

See `Showcase/README.md` for the full walkthrough and how to wire the sample into an Xcode project. It ships as source files, not an `.xcodeproj`, since the framework itself is SPM-only.

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
| `app.MapPost`/`MapPut`/`MapPatch`/`MapDelete` | `app.mapPost`/`mapPut`/`mapPatch`/`mapDelete` |
| `app.MapGroup("/api")` | `app.mapGroup("/api")` |
| `RequireAuthorization()` | `.requireAuthorization(_:)` |
| `[ApiController]` + `[Route]` | `@Controller(_ prefix:)` |
| `[HttpGet]`/`[HttpPost]`/etc. | `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route` |
| Route constraints (`{id:int}`) | Route constraints (`{id:int}`, `{id:uuid}`, `{page?}`, `{*path}`) |
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
| `Results.Created`/`NoContent`/`BadRequest`/`NotFound`/`Unauthorized`/`Forbid`/`Redirect`/`File`/`Stream` | `Results.created`/`noContent`/`badRequest`/`notFound`/`unauthorized`/`forbidden`/`redirect`/`file`/`stream` |
| `ProblemDetails` | `ProblemDetails` (RFC 9457) |
| Custom exception → status code | `throw HttpError(_:_:)` |
| `IServiceCollection.AddSingleton`/`AddTransient` | `builder.services.addSingleton`/`addTransient` |
| `IServiceProvider.GetRequiredService<T>()` | `ctx.services.get(T.self)` |
| `[FromRoute]`/`[FromQuery]`/`[FromHeader]`/`[FromServices]`/`[FromBody]`/`[FromForm]` | Convention-based binding by name/type, or `Header<T>`/`Query<T>`/`Service<T>`/`Form` |
| `appsettings.json` / `appsettings.{Environment}.json` | `appsettings.json` / `appsettings.Development.json` |
| `IHostEnvironment.EnvironmentName` | `builder.environment` (`.development` / `.production`) |
| `IConfiguration` typed options | Typed `Codable` options (`ServerOptions`, `CorsOptions`, `RateLimitOptions`, `AuthOptions`) |
| ASP.NET Core rate limiting middleware | `builder.rateLimit { ... }` (token-bucket, pre-pipeline) |
| Kestrel | The single NIOTransportServices-backed `ServerEngine` |
| `app.UseWebSockets()` + a handler | `app.mapWebSocket(_:_:)` |
| Server-Sent Events (manual) | `app.mapSse(_:_:)` (`SseWriter`/`SseEvent`) |
| Swashbuckle / `AddOpenApi()` | `app.mapOpenApi(title:version:models:)` |
| A DTO's OpenAPI schema (reflection-based) | `@ApiModel` (compile-time, no reflection) |
| Razor Pages / views | `View("page.html", model:)` + the `[[ ]]`-delimited template engine |
| `TestServer` / `WebApplicationFactory` | `SwiftCoreWebTesting.TestHost` |

---

## License

SwiftCoreWeb is licensed under the **[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)**.

- **Free for noncommercial use.** Personal projects, education, research, and evaluation are all fine at no cost.
- **Commercial use requires a separate license from the author.** If your use case makes or supports revenue, get in touch before shipping it.
- The source is publicly readable on GitHub, but this is **not** an OSI-approved open-source license. SwiftCoreWeb is **source-available**, not open-source — please don't call it open-source in code, docs, or conversation.

The full license text is in `LICENSE` at the repository root. Third-party components embedded in this package (the Vue 3 runtime, SwiftNIO, swift-nio-transport-services) keep their own upstream licenses and required notices — see `LICENSE-THIRD-PARTY`.
