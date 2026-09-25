# FAQ and troubleshooting

[← docs index](README.md)

You are here if: you have a specific "why does it do this" or "can I even do X" question and don't
want to read a whole guide to find the answer.

## Basics

#### Why does the server only listen on `127.0.0.1` by default?

Secure by default. Nothing leaves the device, so there's no permission prompt and no Info.plist key
needed. Call `builder.listenOnAllInterfaces()` explicitly to expose the server to the local network
— see [Web track: auth and security](web/AUTH_AND_SECURITY.md) and
[API track: auth and security](api/AUTH_AND_SECURITY.md) for what to protect once you do.

#### Why does `OPTIONS` answer itself without a handler?

Every route you register automatically gets a matching `OPTIONS` response with an `Allow` header
listing the methods that path supports — same for `HEAD`, which mirrors any `GET` route you define.
You never write these by hand.

#### A path exists but the method doesn't match — what happens?

`405 Method Not Allowed`, not `404`. The router distinguishes "no such path" from "path exists, wrong verb".

#### Do I need `Info.plist` changes to run a server on-device?

Only if you call `listenOnAllInterfaces()` or `advertise(name:)` — those put the app on the Wi-Fi
network, which needs `NSLocalNetworkUsageDescription` and `NSBonjourServices` keys so iOS can show
its "Allow this app to find devices on your local network?" prompt. The default loopback-only
binding needs nothing extra. See [Getting started](GETTING_STARTED.md) and
[Web track: auth and security](web/AUTH_AND_SECURITY.md) for the exact keys.

#### Will running a server get my app rejected by App Review?

Not by itself. What gets an app rejected is a missing permission prompt, or personal data left
unprotected on the network. Add the two Info.plist keys above when you expose the server to the
LAN, protect anything personal the server serves with `auth:`, and add a short note in App Review's
"Notes" field explaining why the app runs a server — reviewers who don't get that context sometimes
reject just for clarification.

## What's *not* possible (public API limits, not oversights)

These come up often enough to answer once, here, rather than let you go looking for an API that
doesn't exist:

- **No CPU/battery temperature in °C, no fan %, no GPU %, no Wi-Fi SSID.** iOS has no public API for
  these. The on-device dashboard shows `ProcessInfo.thermalState` (nominal/fair/serious/critical)
  instead of a fake number — the framework never simulates data it can't actually read.
- **No client IPs or request paths persisted to disk.** Aggregated metrics only; per-request detail
  lives in an in-memory ring buffer and is gone on relaunch — by design, since client IPs are
  personal data.
- **No Swift Charts.** Deployment target is iOS 15; anything chart-like is built with plain SwiftUI
  `Path`/`Shape`, so there's no iOS 16 floor just for a chart.
- **Device-assigned name via `UIDevice.name`:** from iOS 16 this returns a generic string unless
  your app has the (restricted) user-assigned-device-name entitlement. The framework shows whatever
  `UIDevice.name` actually returns rather than pretending otherwise.

## What *is* possible, but not obvious

- **Mixing routing styles on one server** — Minimal API closures and `@Controller` macro routes
  coexist fine; the Showcase app does exactly this. See
  [Routing and middleware](ROUTING_AND_MIDDLEWARE.md).
- **Two authentication schemes at once** — e.g. JWT for browser/app clients and a custom API-key
  header for machine-to-machine calls, both registered in one `.useAuthentication(...)` call. See
  [API track: auth and security](api/AUTH_AND_SECURITY.md).
- **Serving a browser-facing site and a native on-device dashboard from the same `WebApplication`**
  — the dashboard only replaces what's on the device's own screen; every HTTP route still serves
  real responses to network clients. See [On-device dashboard guide](web/DASHBOARD_GUIDE.md).
- **Testing the exact production pipeline without a real socket** — `TestHost` runs the same
  `RequestDispatcher`, not a mock. See [Testing guide](TESTING_GUIDE.md).

## Common gotchas

- Secrets in `appsettings.json`: don't. See [Secrets and certificates](SECRETS_AND_CERTIFICATES.md) — the Keychain via `SecretStore` is the only supported source.
- Forgetting `.useExceptionHandler()` first in the middleware chain means unhandled errors won't
  come back as clean `ProblemDetails` — it must be registered before anything that can throw.
- Linking `SwiftCoreWebTesting` into your app target instead of just the test target pulls in test
  infrastructure you don't want shipped.

Didn't find your question here? Check the [docs index](README.md) for the full list, or open an
issue.
