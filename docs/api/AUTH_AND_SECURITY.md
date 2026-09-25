# API track: auth and security

[← docs index](../README.md)

You are here if: your API needs authentication and/or authorization. Same middleware as the Web
track — [`../web/AUTH_AND_SECURITY.md`](../web/AUTH_AND_SECURITY.md) covers page-specific details
(cookies, LAN exposure prompts); this doc focuses on the JSON/token-based patterns typical of APIs.

## JWT bearer auth

```swift
app.useAuthentication(
    .jwt(validate: JwtOptions(hmacSecret: SecretStore.read("jwtSigningSecret")))
)
app.useAuthorization()

app.mapGet("/api/profile", auth: .authenticated) { ctx in
    ctx.user // ClaimsPrincipal? — populated by whichever scheme authenticated the request
}
```

Generating and storing the signing secret: see
[`../SECRETS_AND_CERTIFICATES.md`](../SECRETS_AND_CERTIFICATES.md). If you're validating tokens
issued elsewhere (ES256/RS256), use `JwtOptions(publicKeyPEM:)` instead of `hmacSecret`.

## A custom scheme — API key header

For machine-to-machine calls where a full JWT flow is overkill:

```swift
app.useAuthentication(
    .jwt(validate: JwtOptions(hmacSecret: SecretStore.read("jwtSigningSecret"))),
    .custom("apiKey") { request in
        guard let presented = request.headers["X-Api-Key"] else { return nil }
        guard presented == expectedKey else {
            throw HttpError(.unauthorized, "Invalid API key")
        }
        return ClaimsPrincipal(claims: [Claim(type: "sub", value: "service-account")], roles: ["admin"], scheme: "apiKey")
    }
)
```

Both schemes are registered in one `.useAuthentication(...)` call — either one satisfies
`auth: .authenticated`. Use `auth: .scheme("apiKey")` on a route to require that scheme specifically
(e.g. an internal endpoint no human token should ever reach). Store `expectedKey` the same way as
any other secret — see [`../SECRETS_AND_CERTIFICATES.md`](../SECRETS_AND_CERTIFICATES.md).

## Roles and policies

```swift
app.mapDelete("/api/todos/{id:int}", auth: .roles(["admin"])) { ... }
```

`AuthRequirement`: `.none` (public), `.authenticated` (any scheme), `.roles([...])`, `.policy(name)`
(a named policy registered via the authorization configuration), `.scheme(name)` (one specific
scheme). A route can only combine these by picking the single requirement that matches — for "admin
role AND scheme X", register a named policy that checks both instead.

## HTTP Basic (less common, but built in)

```swift
app.useAuthentication(
    .basic { username, password in
        await userStore.verify(username, password) // constant-time comparison is your responsibility here
    }
)
```

## TLS on your API

```swift
builder.useHttps(p12: .bundle("server.p12"), passwordKeychainKey: "tlsP12Password")
```

See [`../SECRETS_AND_CERTIFICATES.md`](../SECRETS_AND_CERTIFICATES.md) for generating the
certificate (self-signed for development/trusted-LAN, CA-issued for a public domain).

## Rate limiting

```swift
builder.rateLimit { options in
    options.capacity = 60
    options.refillPerSecond = 10
    options.exemptLoopback = true // don't throttle 127.0.0.1 during local dev
}
```

Applied before requests reach your handlers — an offending client gets `429` automatically.
