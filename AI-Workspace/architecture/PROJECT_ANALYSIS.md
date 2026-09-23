# Project Analysis

## Overview

SwiftCoreWeb is a source-available (PolyForm Noncommercial 1.0.0, not OSI open-source) embedded web framework for iOS 15+, published via Swift Package Manager. It lets an iOS app spin up an in-process HTTP/HTTPS/WebSocket server with a .NET Minimal-API-style fluent DX, using SwiftNIO + NIOTransportServices as the sole network stack. 🟢

## Project Structure

1. **Sources/SwiftCoreWeb/** — core library: server engine, routing, middleware, auth, rate limiting, static/SPA hosting, template engine, SSE/WebSocket, OpenAPI (34 files).
2. **Sources/SwiftCoreWebMacros/** — compiler plugin (`SwiftSyntax`) generating controller/route registration code at compile time (6 files).
3. **Sources/SwiftCoreWebTesting/** — `TestHost`, an in-memory pipeline runner for tests (1 file).
4. **Tests/** — `SwiftCoreWebTests` (pipeline/integration) and `SwiftCoreWebMacrosTests` (macro expansion via `assertMacroExpansion`).
5. **Showcase/** — example iOS app (SwiftUI shell + `WKWebView` + one controller) demonstrating the framework end to end; not an SPM library target.
6. **AI-Workspace/** — this knowledge base.

Counted directly from the repository tree (`Sources/**/*.swift`: 45 files across the three targets). 🟢

## Technology Stack

### SwiftNIO + NIOTransportServices
Single transport for HTTP, HTTPS and WebSocket, backed by `Network.framework` via `NIOTSListenerBootstrap`. Bridged to `async`/`await` with `NIOAsyncChannel`; `EventLoopFuture` never surfaces in the public API. 🟢

### Swift Concurrency (Swift 6 strict mode)
`async`/`await` and actors throughout: `RateLimiter`, connection registry, and the live-reload hub are actors; the built router is an immutable `Sendable` value; all handlers are `@Sendable`. 🟢

### Swift Macros (SwiftSyntax)
`@Controller`, `@Get`/`@Post`/`@Put`/`@Patch`/`@Delete`/`@Head`/`@Options`/`@Route`, `@ApiModel` — compile-time only, zero runtime reflection (`Mirror` is never used). Implemented in `SwiftCoreWebMacros` as a `.macro` compiler-plugin target. 🟢

### SwiftUI
Used only in the **Showcase** sample app (`Showcase/ShowcaseApp/Sources/`) for a minimal status screen and a `WKWebView` host, plus binding the server's start/stop to SwiftUI's `ScenePhase`. SwiftUI is not a dependency of the `SwiftCoreWeb` library itself and there is no in-framework component library built with it — see [UI_ANALYSIS.md](../UI_ANALYSIS.md). 🟢

## Design Principles Actually Present in the Code

- **Zero reflection / compile-time safety**: macros emit diagnostics with Fix-Its for placeholder/parameter mismatches, duplicate routes, misuse outside `@Controller`, non-`Sendable` controllers. 🟢
- **Secure by default**: binds to `127.0.0.1:8080` unless `listenOnAllInterfaces()` is called explicitly; secrets (JWT keys, `.p12` password) come from the Keychain, never from JSON config. 🟢
- **Early-gate traffic protection**: rate limiting and the connection cap run before any body bytes are read, ahead of the middleware pipeline. 🟢

Apple Human Interface Guidelines, "Soft UI" and general accessibility are goals stated for the *showcase app's* UI in the original design prompt, not properties of the server framework itself — there is no visual design system to analyze inside `Sources/`. 🟡

## Testing Approach

`SwiftCoreWebTesting.TestHost` drives the exact same middleware/routing/dispatch chain as production, without real sockets, via NIO's `NIOAsyncTestingChannel`. Macro output and every documented diagnostic are covered separately with `assertMacroExpansion` in `Tests/SwiftCoreWebMacrosTests/ControllerMacroTests.swift`. Per the delivery log in [framework_http_server_prompt.md](../Prompts/framework_http_server_prompt.md), the suite passed 11/11 macro tests and 7/7 test-host tests at last verified build. 🟢

## Review Checklist

- Completeness
  - [x] Project structure analyzed against actual file tree
  - [x] Technology stack examined
  - [x] Testing approach documented
- Accuracy
  - [x] Verified against `Sources/`, `Tests/`, `Showcase/` listings and `Package.swift` (2026-09-24)
- Consistency
  - [x] Cross-referenced with [ARCHITECTURE.md](ARCHITECTURE.md)
- TODO
  - [ ] Re-run file count check if source tree changes materially
- Missing information
  - [ ] None at this time
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code, 🟡 where noted (showcase-only design goals)
