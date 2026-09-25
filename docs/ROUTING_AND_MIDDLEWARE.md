# Routing and middleware

[← docs index](README.md)

You are here if: you know Hello World already and want to understand how requests actually flow
through the framework — this underlies both the Web and API tracks.

## Two routing styles, pick per route

**Minimal API closures** — fastest to write, good for small route sets:

```swift
app.mapGet("/hello") { "Hello, world!" }
app.mapPost("/todos") { (ctx: HttpContext, todo: Todo) in
    // ...
    Results.created(location: "/todos/\(todo.id)", todo)
}
```

`mapGet`, `mapPost`, `mapPut`, `mapPatch`, `mapDelete`, `mapHead`, `mapOptions`, `mapMethods([...], ...)`
all exist. Group routes with `app.mapGroup("/api").requireAuthorization()`.

**Macro-based controllers** — for larger, class-organized route sets:

```swift
@Controller("/todos")
final class TodoController {
    @Get("/{id:int}")
    func get(id: Int) async throws -> Todo { ... }

    @Post("")
    func create(_ todo: Todo) async throws -> Todo { ... }
}

app.mapControllers(TodoController.self)
```

`@Controller` generates route registration at compile time — no runtime reflection, no type
discovery magic. `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route` mark each
handler method.

Both styles run through the exact same pipeline — mixing them on one server (as the Showcase app
does) is normal, not a compromise.

## Route templates

- Typed constraints: `{id:int}`, `{id:uuid}`
- Optional segments: `{page?}`
- Catch-alls: `{*path}`
- `HEAD` is served automatically for every `GET` route
- `OPTIONS` is answered automatically with an `Allow` header
- A path match with no method match returns `405`

## Handler parameters bind automatically, in this order

1. An `HttpContext` parameter is injected.
2. A name matching a route placeholder binds from the path.
3. A non-primitive `Decodable` on `POST`/`PUT`/`PATCH` binds from the JSON body.
4. A primitive or optional primitive binds from the query string.
5. `Header<T>`, `Query<T>`, `Service<T>`, and `Form` give explicit control when the convention isn't enough.

Any conversion failure produces a `400` `ProblemDetails` naming the offending parameter — you never
have to write that check yourself.

The macro compiler plugin also catches mistakes at compile time, with Fix-Its where possible: a
placeholder with no matching parameter (and vice versa), an unsupported parameter/return type, a
duplicate method+path, a marker used outside `@Controller`, a non-`Sendable` controller, invalid
route syntax.

## Middleware

A sequential async pipeline, in the style of ASP.NET's `IApplicationBuilder`:

```swift
app.use { ctx, next in
    // before
    try await next()
    // after
}
```

Or a reusable `Middleware` conformance for something you'll register on multiple apps. Middleware
runs in registration order — order matters, especially for the exception handler (must be first).

Built-ins:

| Call | What it does |
|---|---|
| `.useExceptionHandler()` | Always first; turns any thrown error into an RFC 9457 `ProblemDetails` response |
| `.useCors(_:)` | Cross-origin resource sharing |
| `.useSecurityHeaders()` | Standard security response headers, including a `Content-Security-Policy` |
| `.useAuthentication(_:)` | Pluggable auth schemes — see [`SECRETS_AND_CERTIFICATES.md`](SECRETS_AND_CERTIFICATES.md) for setting up JWT signing keys |
| `.useAuthorization(policies:)` | Role/policy checks after authentication |
| `.useStaticFiles(root:)` | Serves files as-is (Web track) |
| `.useRequestLogging()` | Structured request logs via `os.Logger` |

## Server engine, in one sentence

A single `NIOTSListenerBootstrap` (Network.framework via `NIOTransportServices`) serves HTTP and,
when TLS is configured, HTTPS on the same pipeline. Handler code is plain `async throws` — never
`EventLoopFuture` — thanks to `NIOAsyncChannel` bridging NIO to Swift Concurrency.
