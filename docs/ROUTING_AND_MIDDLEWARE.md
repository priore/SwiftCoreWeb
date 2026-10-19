# Routing and middleware

[← docs index](README.md)

You are here if: you know Hello World already and want to understand how requests actually flow
through the framework — this underlies both Web and API guides.

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

- Constraints: `{id:int}`, `{id:uuid}`, chained as `{id:int:min(1)}` (all must match)
- Optional segments: `{page?}`
- Catch-alls: `{*path}`
- `HEAD` is served automatically for every `GET` route
- `OPTIONS` is answered automatically with an `Allow` header
- A path match with no method match returns `405`

### Constraints

| Constraint | Matches | Typical Swift type |
|---|---|---|
| `int` | `Int(value) != nil` | `Int` |
| `long` | `Int64(value) != nil` | `Int64` |
| `uuid` | a valid UUID string | `UUID` |
| `bool` | exactly `true` or `false` (lowercase; stricter than ASP.NET) | `Bool` |
| `double` | `Double(value) != nil` | `Double` |
| `alpha` | one or more ASCII letters | `String` |
| `min(n)`, `max(n)`, `range(a,b)` | an integer within the bounds | `Int` / `Int64` |
| `length(n)`, `length(a,b)`, `minlength(n)`, `maxlength(n)` | character count within the bounds | `String` |

A constraint only decides whether the route matches; the handler parameter's declared type does the
conversion. In a controller, a constraint that cannot bind to the parameter's type
(`{id:int}` with `id: UUID`) is a compile-time error. Unknown or malformed constraints are rejected
at registration. `regex(...)` is intentionally not supported (ReDoS risk, per-request cost), and
`datetime`, `decimal`, `float` depend on locale: take a `String` and convert in the handler.

Constraints behave the same for closure and controller routes: `/users/abc` against `{id:int}` is
a `404` (or falls through to another route), not a `400`.

### Route precedence

When several routes match a request path for the same method, the most specific wins, **whatever
the registration order**. Segments are compared left to right with this ranking:

literal > constrained parameter > parameter > optional parameter > catch-all

| Request | Routes | Winner |
|---|---|---|
| `/users/me` | `/users/{id}`, `/users/me` | `/users/me` |
| `/users/42` | `/users/{name}`, `/users/{id:int}` | `/users/{id:int}` |
| `/a/x` | `/a/{rest?}`, `/a/{*rest}` | `/a/{rest?}` |
| `/a` | `/a/{page?}`, `/a` | `/a` |

### Ambiguous routes fail at startup

Two routes for the same method whose templates differ only in placeholder names
(`/users/{id}` and `/users/{name}`) can never be told apart: the second would be unreachable. The
server refuses to start and names both routes. Different constraints are different shapes
(`{id:int}` and `{id:uuid}` are fine). Constraints that overlap without being identical
(`{id:int}` and `{id:min(1)}`) are not reported; precedence rules above decide, and ties go to the
route registered first.

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
| `.useAuthentication(_:)` | Pluggable auth schemes — see [Secrets and certificates](SECRETS_AND_CERTIFICATES.md) for setting up JWT signing keys |
| `.useAuthorization(policies:)` | Role/policy checks after authentication |
| `.useStaticFiles(root:)` | Serves files as-is (Web) |
| `.useRequestLogging()` | Structured request logs via `os.Logger` |

## Server engine, in one sentence

A single `NIOTSListenerBootstrap` (Network.framework via `NIOTransportServices`) serves HTTP and,
when TLS is configured, HTTPS on the same pipeline. Handler code is plain `async throws` — never
`EventLoopFuture` — thanks to `NIOAsyncChannel` bridging NIO to Swift Concurrency.
