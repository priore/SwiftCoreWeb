# SwiftCoreWeb

[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE)
[![Swift](https://img.shields.io/badge/swift-6-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2015%2B%20%7C%20macOS%2011%2B%20%7C%20tvOS%2015%2B-lightgrey)](README.md#requirements)
[![SwiftNIO](https://img.shields.io/badge/SwiftNIO-2.65-blue)](https://github.com/apple/swift-nio)
[![Vue](https://img.shields.io/badge/Vue-3-brightgreen?logo=vuedotjs)](https://vuejs.org)
[![SQLite](https://img.shields.io/badge/SQLite-3-lightblue?logo=sqlite)](https://sqlite.org)
[![Docs](https://img.shields.io/badge/docs-wiki-blue)](docs/README.md)
[![OpenSSF Baseline](https://www.bestpractices.dev/projects/15128/baseline)](https://www.bestpractices.dev/projects/15128)
[![Security Policy](https://img.shields.io/badge/security-policy-orange)](SECURITY.md)
[![Contributing](https://img.shields.io/badge/contributing-guide-informational)](CONTRIBUTING.md)
[![Donate with PayPal](https://img.shields.io/badge/PayPal-donate-blue?logo=paypal)](https://paypal.me/prioregroup)
[![Donate with BITCOIN](https://img.shields.io/badge/BITCOIN-donate-green?logo=bitcoin)](https://github.com/priore/SwiftCoreWeb#support-development)
[![Star History](https://img.shields.io/badge/⭐-Star%20History-blue)](https://star-history.com/#priore/SwiftCoreWeb&Date)

Your iPhone can run a real web server. SwiftCoreWeb turns any iOS 15+ app into a full HTTP/HTTPS/WebSocket backend, no separate server needed. Same fluent, Minimal-API feel .NET developers already love, done in idiomatic Swift, with **zero runtime reflection**.

---

## Features

### Server

- **HTTP and HTTPS** on SwiftNIO. TLS comes from a PKCS#12 identity whose password stays in the Keychain.
- **Secure by default**: the server listens on loopback only, until you opt in to the LAN.
- **WebSocket and Server-Sent Events** routes, with limits on frame and message size, backpressure, and a clean close handshake.
- **Static files and single-page apps**, byte ranges, file upload and download, one-time download links.
- **Two ways to write routes, on the same server**: Minimal API closures and macro-based `@Controller`s. Route templates, parameter binding from route, query and body, per-route body limits.
- **Middleware pipeline**: authentication, CORS, security headers, logging, exception handling, rate limiting, cookie sessions.
- **Dependency injection**, `ProblemDetails` error bodies, generated OpenAPI documentation.
- **Built for iOS apps**: keep-awake, scene-phase binding, restart after backgrounding, network-change handling, Bonjour announcement.

### Authentication and secrets

- JWT bearer and custom API-key schemes, plus authorization policies.
- Signing keys and TLS passwords live in the Keychain (`SecretStore`), never in a file.
- Guide: [Secrets & certificates](docs/SECRETS_AND_CERTIFICATES.md).

### Front end

- Plain HTML, or server-rendered templates.
- Zero-build Vue, or a full Vite workflow with on-device dev-deploy and live reload.
- [Live Pages](docs/web/LIVE_PAGES_GUIDE.md): Vue components wired to Swift event handlers. A click in the browser runs Swift on the server and the page updates.

### Peer-to-peer access (`SwiftCoreWebP2P`, optional)

Reach the app from a paired iPhone, iPad, Mac or Apple TV with no open port and no server in between. Full guide: [docs/P2P_TRANSPORT.md](docs/P2P_TRANSPORT.md).

- **Standard protocol**: SSH with Ed25519 keys and `direct-tcpip` forwarding. Any HTTP client works through a loopback URL, and so does OpenSSH.
- **Pairing**: a QR code, or a six-digit code with the host key confirmed by eye on devices without a camera (Apple TV).
- **Control**: per-device identity and revocation, and per-route rules for what a paired device can reach.
- **On the same network**: the host is found again by Bonjour when its address changes.
- **From another network**: a direct connection (TCP hole punching) is tried first, then a TURN relay. The small rendezvous service they need can run on a plain SwiftCoreWeb app.
- **Resilient**: the connection follows network changes (Wi-Fi to cellular) and reconnects by itself.
- **Status**: verified on the simulator and the loopback. Not yet tried on real devices or across real NATs.

### Testing

- `TestHost` runs the real production pipeline in memory, with no sockets (`SwiftCoreWebTesting`).

### Optional libraries

| Library | What it adds |
|---------|--------------|
| `SwiftCoreWebDashboard` | Turns the device's screen into a live console for the server running on it |
| `SwiftCoreWebKit` | Makes blob and attachment downloads work inside a `WKWebView` |
| `SwiftCoreWebP2P` | Peer-to-peer access, as above |

### Platforms

iOS 15+, macOS 11+ and tvOS 15+. On tvOS there is no screen dimming, battery metrics, pasteboard or WebKit helper.

---

## Requirements

- iOS 15.0+ deployment target (also macOS 11+ and tvOS 15+; on tvOS screen dimming, battery metrics, the pasteboard and the WebKit helper are not available)
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

## Your first interactive page

A click in the browser runs Swift on the server, and the page updates — no client-side JS to write.

```swift
struct CounterPage: Page {
    static let template = "counter.html"
    var count = 0

    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction {
        if event == "increment" { count += 1 }
        return .render
    }
}

app.useVue()
app.usePages(root: .bundle("Views"))
app.mapPage("/counter", CounterPage.self)
```

`Views/counter.html` — a Vue template, nothing else:

```html
<button @click="$swift('increment')">Count: {{ count }}</button>
```

Three rules: `form` fields (none here) are what the user edits; every other property is server
state the browser can see but not change; `$swift('name')` calls `onEvent("name")` in Swift. See
[docs/web/LIVE_PAGES_GUIDE.md](docs/web/LIVE_PAGES_GUIDE.md) for every input type, validation, and session state.

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
- **Building a web app?** → [docs/web/](docs/web/GETTING_STARTED.md) — pages, Vue, Live Pages, sessions, the on-device dashboard
- **Building an API?** → [docs/api/](docs/api/GETTING_STARTED.md) — JSON routes, auth, OpenAPI, CRUD

---

## Showcase

`Showcase/` is one real iOS app with a menu: every entry starts its own server and shows what it serves. It compiles against the actual API, and includes:

- Hello World: a static Vue page and a JSON route
- A macro-based `@Controller` alongside closure Minimal API routes, JWT and API-key authentication, OpenAPI
- [Live Pages](docs/web/LIVE_PAGES_GUIDE.md), Server-Sent Events and a WebSocket echo
- The [on-device dashboard](docs/web/DASHBOARD_GUIDE.md)
- [Peer-to-peer access](docs/P2P_TRANSPORT.md): host, client (pairs from a QR code scanned with the Camera app), and a rendezvous server

It also walks through the three frontend workflows (Vite on the Mac, on-device dev-deploy, a production build phase) and how to try peer-to-peer from another network.

Open `Showcase/ShowcaseApp/ShowcaseApp.xcodeproj` and press Run; see `Showcase/README.md` for the details.

---

## On-device dashboard and .NET naming table

Two more things worth knowing exist, kept out of this file to keep it short:

- **[On-device dashboard](docs/web/DASHBOARD_GUIDE.md)** — turn the device's own screen into a live console (request rate, latency, CPU/memory/battery/thermal state) instead of whatever your app would otherwise show. One line of SwiftUI (`SwiftCoreWebDashboardView(app: app)`), opt-in library target, the HTTP server keeps serving pages exactly as before.
- **[.NET naming table](docs/DOTNET_MAPPING.md)** — coming from ASP.NET Core Minimal APIs? Every `WebApplication.CreateBuilder()`/`MapGet`/`UseAuthentication`/etc. has a direct SwiftCoreWeb equivalent, listed side by side.

---

## Building in Xcode: enabling the macro plugin

Like every Swift package that ships macros, SwiftCoreWeb asks Xcode for a one-time approval of its macro plugin (`SwiftCoreWebMacros`) the first time you build: click **Trust & Enable**. It is a standard Apple prompt shown for any package with macros, not a warning about this one.

Why it is safe, all checkable in [`Sources/SwiftCoreWebMacros/`](Sources/SwiftCoreWebMacros) (about 900 lines):

- **It only rewrites source code.** The macros (`@Controller`, the route attributes such as `@Get`/`@Post`, `@ApiModel`) read the declaration they are attached to and generate Swift source (the route table and parameter-binding code). You can see exactly what they produce with *Right-click → Expand Macro* in Xcode.
- **It touches nothing else.** The plugin imports only `SwiftSyntax`, `SwiftSyntaxMacros`, `SwiftSyntaxBuilder`, `SwiftDiagnostics` and `SwiftCompilerPlugin`. It does not import `Foundation` and has no code for files, network, processes or environment variables.
- **It never ships in your app.** It runs on your Mac at compile time only; nothing from it is linked into your binary, so there is no runtime cost and no runtime access.
- **Its only dependency is Apple's.** [`swift-syntax`](https://github.com/apple/swift-syntax) is the package every Swift macro is built on.

Xcode stores the approval per macro and package version, so the prompt can come back after you update SwiftCoreWeb.

**CI / command line:** `xcodebuild` cannot show the prompt, so the build fails until the macro is approved. Pass `-skipMacroValidation` (only for packages you have reviewed, like this one) or approve it once in Xcode.

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
