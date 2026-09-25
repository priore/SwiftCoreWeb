# Testing guide

[← docs index](README.md)

You are here if: you've written some routes and want to test them without binding a real socket or
running the Simulator.

## `TestHost` — the same pipeline, no network

`SwiftCoreWebTesting.TestHost` runs the *exact same* handler chain as production — the same
`RequestDispatcher` handling routing, middleware, auth, and handlers — just driven through an
in-memory `NIOAsyncTestingChannel` instead of a bound socket. Link `SwiftCoreWebTesting` to your
test target only, never your app target.

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

`get`/`post`/`put`/`patch`/`delete`/`head`/`options` cover every HTTP method, each with optional
headers and either a raw `Data` body or a `json:` parameter that encodes an `Encodable` value for
you. `TestResponse.decode(_:)` decodes JSON; `.bodyString` gives you the raw text when you need it
(error messages, HTML pages).

## Testing auth

Build the app with `.useAuthentication(...)` configured exactly as in production, then send a
request with the right header:

```swift
let res = try await host.get("/api/admin", headers: [("Authorization", "Bearer \(testToken)")])
#expect(res.status == 200)

let unauthorized = try await host.get("/api/admin")
#expect(unauthorized.status == 401)
```

Generate `testToken` with the same HMAC secret your test build's `JwtOptions` uses — see
[`SECRETS_AND_CERTIFICATES.md`](SECRETS_AND_CERTIFICATES.md) for how signing secrets are meant to
be generated and stored; tests can use a throwaway fixed secret since nothing here talks to a real
network.

## Testing error paths

Any thrown `HttpError` or unhandled error goes through `.useExceptionHandler()` and comes back as
an RFC 9457 `ProblemDetails` JSON body — assert on `res.status` and decode
`res.decode(ProblemDetails.self)` to check the `detail`/`title` fields.

## Testing middleware ordering

Since `TestHost` runs the real pipeline, ordering bugs (e.g. authorization running before
authentication) show up the same way they would in production — register middleware in the same
order you would for real, then assert on the response your handler actually receives (e.g. a
`ctx.user` that should or shouldn't be populated).

## CI

The project's CI runs the same build-and-test steps you'd run locally — see the `ci-local` skill
(or `.github/workflows/ci.yml` directly) to run everything before pushing.
