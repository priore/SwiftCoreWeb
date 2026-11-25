# Getting started

[← docs index](README.md)

You are here if: you've never touched SwiftCoreWeb and want to go from "nothing" to "a server
running on my iPhone" as fast as possible.

## Requirements

- iOS 15.0+ deployment target
- Xcode 16+ / Swift 6 language mode
- Dependencies: `swift-nio`, `swift-nio-transport-services`, `swift-syntax` (macros only, compile time). Everything else — TLS, JWT, logging, network monitoring — uses system frameworks.

## Add the package

In Xcode: **File → Add Package Dependencies…**, point it at this repository (or a local path), and
link the `SwiftCoreWeb` library to your app target. If you're writing tests, also link
`SwiftCoreWebTesting` — but only to the test target, never the app target.

## Hello World

```swift
import SwiftCoreWeb

let app = WebApplication.createBuilder().build()
app.mapGet("/hello") { "Hello, world!" }
try await app.runAsync()
```

Binds to `127.0.0.1:8080` by default — secure by default, no LAN exposure until you explicitly opt
in with `builder.listenOnAllInterfaces()`. Run this on the Simulator or a device, then
`curl http://127.0.0.1:8080/hello`.

## What next?

Pick a starting point based on what you're building:

- **Serving pages/UI to a browser or WebView** → [Web: getting started](web/GETTING_STARTED.md)
- **Serving JSON/REST to another app or service** → [API: getting started](api/GETTING_STARTED.md)

Both share the same routing and middleware system — read
[Routing and middleware](ROUTING_AND_MIDDLEWARE.md) once, it applies to both.

## Try the real thing: the Showcase app

`Showcase/` is a complete sample app — not a toy: one iOS app with a menu where each entry runs a real
server (a Vue page, a macro-based `@Controller` API with two auth schemes, Live Pages, SSE and WebSocket, the
on-device dashboard, and peer-to-peer host and client). Open `Showcase/ShowcaseApp/ShowcaseApp.xcodeproj` and
press Run; `Showcase/README.md` has the walkthrough, including the three frontend workflows.
