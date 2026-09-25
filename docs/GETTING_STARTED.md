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

Pick a track based on what you're building:

- **Serving pages/UI to a browser or WebView** → [Web track: getting started](web/GETTING_STARTED.md)
- **Serving JSON/REST to another app or service** → [API track: getting started](api/GETTING_STARTED.md)

Both share the same routing and middleware system — read
[Routing and middleware](ROUTING_AND_MIDDLEWARE.md) once, it applies to both tracks.

## Try the real thing: the Showcase app

`Showcase/` is a complete, compilable sample app — not a toy. It demonstrates a macro-based
`@Controller` alongside closure Minimal API routes on the same server, two auth schemes, SwiftUI
lifecycle binding, and all three frontend workflows (Vite on the Mac, on-device dev-deploy, and a
production build). It ships as source files, not an `.xcodeproj` (the framework itself is SPM-only),
so wiring it into a project is a five-minute manual step — see `Showcase/README.md` for the full
walkthrough.
