# SwiftCoreWeb

[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE)
[![Swift](https://img.shields.io/badge/swift-6-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-lightgrey)](README.md#requirements)
[![SwiftNIO](https://img.shields.io/badge/SwiftNIO-2.65-blue)](https://github.com/apple/swift-nio)
[![Vue](https://img.shields.io/badge/Vue-3-brightgreen?logo=vuedotjs)](https://vuejs.org)
[![SQLite](https://img.shields.io/badge/SQLite-3-lightblue?logo=sqlite)](https://sqlite.org)
[![Docs](https://img.shields.io/badge/docs-wiki-blue)](docs/README.md)
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

`WebApplication.createBuilder()` gives you a fluent builder for ports/TLS/limits/DI, one router
that mixes Minimal API closures and macro-based `@Controller`s, a middleware pipeline (auth, CORS,
security headers, logging), zero-build Vue or a full Vite workflow for the frontend, and a
`TestHost` that runs the real production pipeline in-memory. Every one of these has its own short
guide with runnable examples — the full index is [`docs/README.md`](docs/README.md):

- [Getting started](docs/GETTING_STARTED.md)
- [Routing & middleware](docs/ROUTING_AND_MIDDLEWARE.md)
- [Secrets & certificates](docs/SECRETS_AND_CERTIFICATES.md)
- [Testing](docs/TESTING_GUIDE.md)
- [FAQ](docs/FAQ_AND_TROUBLESHOOTING.md)
- **Building a web app?** → [docs/web/](docs/web/GETTING_STARTED.md) — pages, Vue, sessions, the on-device dashboard
- **Building an API?** → [docs/api/](docs/api/GETTING_STARTED.md) — JSON routes, auth, OpenAPI, CRUD

---

## Showcase

`Showcase/` is a complete, real end-to-end sample app — not a toy. It compiles against the actual API, and includes:

- A SwiftUI app whose device screen shows the [on-device dashboard](docs/web/DASHBOARD_GUIDE.md) while `/` keeps serving the site to browsers
- A macro-based `@Controller` alongside closure Minimal API routes, on the same server
- Two authentication schemes: JWT and a custom API-key header
- SwiftUI `ScenePhase` lifecycle binding, plus keep-awake

It also walks through the three frontend workflows you'll actually use, and ships ready-to-copy `Info.plist` keys, `vite.config.js`, and both scripts:

- Vite on the Mac with API proxying
- on-device dev-deploy with live reload
- a production Xcode build phase that copies `dist/` into the bundle

See `Showcase/README.md` for the full walkthrough and how to wire the sample into an Xcode project. It ships as source files, not an `.xcodeproj`, since the framework itself is SPM-only.

---

## On-device dashboard and .NET naming table

Two more things worth knowing exist, kept out of this file to keep it short:

- **[On-device dashboard](docs/web/DASHBOARD_GUIDE.md)** — turn the device's own screen into a live console (request rate, latency, CPU/memory/battery/thermal state) instead of whatever your app would otherwise show. One line of SwiftUI (`SwiftCoreWebDashboardView(app: app)`), opt-in library target, the HTTP server keeps serving pages exactly as before.
- **[.NET naming table](docs/DOTNET_MAPPING.md)** — coming from ASP.NET Core Minimal APIs? Every `WebApplication.CreateBuilder()`/`MapGet`/`UseAuthentication`/etc. has a direct SwiftCoreWeb equivalent, listed side by side.

---

## License

SwiftCoreWeb is licensed under the **[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)**.

- **Free for noncommercial use.** Personal projects, education, research, and evaluation are all fine at no cost.
- **Commercial use requires a separate commercialization agreement with the author.** If your use case makes or supports revenue, get in touch before shipping it.
- The source is publicly readable on GitHub, but this is **not** an OSI-approved open-source license. SwiftCoreWeb is **source-available**, not open-source — please don't call it open-source in code, docs, or conversation.

The full license text is in `LICENSE` at the repository root. Third-party components embedded in this package (the Vue 3 runtime, SwiftNIO, swift-nio-transport-services) keep their own upstream licenses and required notices — see `LICENSE-THIRD-PARTY`.

Want to contribute? Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Found a security issue? See [SECURITY.md](SECURITY.md), don't open a public issue.

---

## Support Development

If this project has been useful to you, consider a small donation. Every contribution helps fund new features and keep the project active.

Scan the code below with your wallet, or copy the address. Alternatively you can donate via [PayPal](https://paypal.me/prioregroup).

|Donate with BTC (Bitcoin)|
|:------------:|
|![](https://www.prioregroup.com/images/priore_btc_segwit_binance.jpg)|
|`BTC Address (SegWit) : bc1q6rj0uuwu9k2fvs5n5elmqy9v4ljazhexejykjm`|
