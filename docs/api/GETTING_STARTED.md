# API: getting started

[← docs index](../README.md)

You are here if: you're serving JSON/REST to another app, service, or SPA frontend, not (only)
HTML pages. Read [Getting started](../GETTING_STARTED.md) and
[Routing and middleware](../ROUTING_AND_MIDDLEWARE.md) first if you haven't yet.

## Your first JSON route

```swift
struct User: Encodable, Sendable {
    let id: Int
    let name: String
}

app.mapGet("/api/users/{id:int}") { (id: Int) in
    User(id: id, name: "Mario")
}
```

Any `Encodable` return value is serialized to JSON automatically — no manual `JSONEncoder` call, no
explicit `Content-Type` header.

## Shaping responses with `Results`

For anything beyond "200 OK with this body", use the `Results` factory (mirrors .NET Minimal APIs'
`Results` type):

```swift
app.mapPost("/api/users") { (user: User) in
    Results.created(location: "/api/users/\(user.id)", user)
}

app.mapGet("/api/users/{id:int}") { (id: Int) in
    guard let user = store.find(id) else { return Results.notFound() }
    return Results.ok(user)
}
```

`Results.ok`, `.created(location:_:)`, `.noContent`, `.badRequest`, `.notFound`, `.unauthorized`,
`.forbidden`, `.redirect`, `.file`, `.stream` cover the common cases.

## Errors: `ProblemDetails` for free

Any thrown error becomes an RFC 9457 `ProblemDetails` JSON response automatically, as long as
`.useExceptionHandler()` is registered first in your middleware pipeline:

```swift
app.mapGet("/api/users/{id:int}") { (id: Int) in
    guard let user = store.find(id) else {
        throw HttpError(.notFound, "No user with id \(id)")
    }
    return user
}
```

A binding failure (wrong type in a route/query parameter, malformed JSON body) also produces a
`400` `ProblemDetails` naming the offending parameter automatically — you never write that check.

## Next

- [Basic examples](EXAMPLES_BASIC.md) — parameter binding from query/route/body.
- [Advanced examples](EXAMPLES_ADVANCED.md) — a full CRUD API, `@ApiModel`, OpenAPI, DI, rate limiting.
- [Auth and security](AUTH_AND_SECURITY.md) — JWT, API keys, authorization policies.
