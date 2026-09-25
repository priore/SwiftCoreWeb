# Web track: auth and security

[← docs index](../README.md)

You are here if: your pages need to be protected, share state across requests, or you're exposing
the server beyond `127.0.0.1`.

## Protecting a page

Every `map*` call takes an `auth:` parameter:

```swift
app.mapGet("/admin") { _ in
    View("admin.html")
}
// becomes:
app.mapGet("/admin", auth: .authenticated) { _ in
    View("admin.html")
}
```

`AuthRequirement` options: `.none` (default, public), `.authenticated` (any valid identity from any
registered scheme), `.roles([...])`, `.policy(name)`, `.scheme(name)` (require one specific scheme).
Set up the schemes themselves with `.useAuthentication(...)` — see
[Secrets and certificates](../SECRETS_AND_CERTIFICATES.md) for generating the JWT signing
secret, and [API track: auth and security](../api/AUTH_AND_SECURITY.md) for the full scheme setup
(applies identically to web routes and API routes — it's the same middleware).

Group several protected pages instead of repeating `auth:` on each:

```swift
app.mapGroup("/admin").requireAuthorization()
```

## CORS

Only relevant if your page's JS calls a *different* origin (e.g. Vite dev server on the Mac calling
the API on-device — Mode A in `Showcase/README.md`). Same-origin pages (the common case — page and
API served by the same `WebApplication`) need no CORS configuration at all.

```swift
app.useCors { options in
    options.allowedOrigins = ["http://localhost:5173"]
}
```

## Security headers

```swift
app.useSecurityHeaders()
```

Adds standard response headers including a `Content-Security-Policy`. If a page needs inline
`<script>`, either move the script to an external file (recommended) or adjust the policy — check
the header value in a browser's network tab if a page mysteriously refuses to run its JS.

## Exposing the server beyond `127.0.0.1`

```swift
builder.listenOnAllInterfaces()
builder.advertise(name: "my-iphone") // optional Bonjour discovery
```

This requires two `Info.plist` keys so iOS can show its "Allow this app to find devices on your
local network?" prompt:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app runs a local web server so you can view its content from a browser on the same Wi-Fi network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_http._tcp</string>
</array>
```

Write `NSLocalNetworkUsageDescription` in plain words describing what your app actually does — the
text above is a generic starting point, not a value to copy verbatim into a shipping app.
`NSBonjourServices` only matters if you call `advertise(name:)`; without it, advertising just fails
silently instead of showing the prompt.

Anything personal a LAN-exposed page serves should require `auth:` unless the network is fully
trusted — see [FAQ and troubleshooting](../FAQ_AND_TROUBLESHOOTING.md) for the full App
Store review guidance, including the "Notes" field wording reviewers expect.

## HTTPS

```swift
builder.useHttps(p12: .bundle("server.p12"), passwordKeychainKey: "tlsP12Password")
```

See [Secrets and certificates](../SECRETS_AND_CERTIFICATES.md) for generating the `.p12`
itself (self-signed or CA-issued) and storing its password.
