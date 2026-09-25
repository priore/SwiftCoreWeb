# API track: basic examples

[← docs index](../README.md)

You are here if: you want a small, complete, copy-pasteable example — one concept each.

## GET with a route parameter

```swift
app.mapGet("/api/users/{id:int}") { (id: Int) in
    User(id: id, name: "Mario")
}
```

A name matching a route placeholder (`{id:int}` ↔ parameter `id`) binds from the path automatically.

## GET with a query parameter

```swift
app.mapGet("/api/search") { (q: String, limit: Int?) in
    // GET /api/search?q=swift&limit=10
    ["result for \(q)"]
}
```

A primitive or optional primitive parameter with no matching route placeholder binds from the query
string. `limit` is optional (`Int?`) — missing from the URL means `nil`, not an error.

## GET with the `Query<T>`/`Header<T>` wrappers, on a `@Controller` method

Only `@Controller` methods can use these — the macro reads the wire name straight from the Swift
parameter's own external label, so it must be a declared function parameter, not a closure
parameter:

```swift
@Get("/search")
func search(q: Query<String>) async throws -> [String] {
    ["result for \(q.wrappedValue ?? "")"]
}
```

`GET /api/search?q=swift` binds `q`. On a Minimal API closure (`mapGet`/`mapPost`), a plain optional
primitive parameter already binds from the query string by name convention (see the first example
above) — that covers the common case without needing the wrapper at all.

## POST with a JSON body

```swift
struct CreateUserRequest: Decodable, Sendable {
    let name: String
    let email: String
}

app.mapPost("/api/users") { (request: CreateUserRequest) in
    Results.created(location: "/api/users/1", User(id: 1, name: request.name))
}
```

A non-primitive `Decodable` parameter on `POST`/`PUT`/`PATCH` binds from the JSON body
automatically — no explicit `Content-Type` check, no manual decoding.

## Reading a header explicitly

```swift
@Get("/whoami")
func whoami(authorization: Header<String>) async throws -> String {
    "Authorization header was: \(authorization.wrappedValue ?? "none")"
}
```

The Swift parameter's own external label is the header name looked up (matched case-insensitively,
so `authorization` matches `Authorization`) — there's no separate name argument to pass. This only
works for header names that are also legal Swift identifiers (no hyphens); a header like
`X-Request-Id` can't be bound this way — read it from `ctx.request.headers["X-Request-Id"]` inside
a Minimal API closure instead.

## Next

[Advanced examples](EXAMPLES_ADVANCED.md) builds a full CRUD API with `@ApiModel`, DI, rate
limiting, and OpenAPI docs.
