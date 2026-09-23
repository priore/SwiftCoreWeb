# Product Roadmap

## Overview

This replaces a previous draft that invented five speculative phases (including "Android platform support" and "WebAssembly integration") with no basis in the project. SwiftCoreWeb targets iOS 15+ only; there is no stated multi-platform goal anywhere in the prompts or code. 🟢 The roadmap below reflects the actual delivery history recorded in [framework_http_server_prompt.md](../Prompts/framework_http_server_prompt.md).

## Delivered (per the build log in the generation prompt)

| Part | Scope | Status |
|---|---|---|
| 1 | `Package.swift`, licensing files, options models, `WebApplicationBuilder`/`WebApplication`, `HttpContext`/`HttpRequest`/`HttpResponse`, macro declarations | 🟢 Done |
| 2 | Full package compiles; 11/11 macro tests, 7/7 test-host tests passing at last verified build | 🟢 Done |
| 3 | Routing & middleware: route matcher, router, pipeline, exception handler, CORS, security/logging, authentication/authorization, parameter binding, dispatcher | 🟢 Done |
| 4 | Server engine & lifecycle: `ServerEngine`, `RateLimiter`, `NetworkWatchdog`, `LifecycleSupport` | 🟢 Done |
| 5 | Web hosting: static files, SPA hosting, template engine, `View`, SSE, WebSocket, OpenAPI, dev deploy, embedded Vue runtime | 🟢 Done |
| 6 | Testing & Showcase: `TestHost`, macro tests, full Showcase app | 🟢 Done |

All 6 parts are marked delivered against the Expected Output Structure in the generation prompt. 🟢

## Known open item

`swift-collections` is pinned to `exact: "1.6.0"` in `Package.swift` as a workaround for a runtime symbol (`_swift_initBorrow`) missing on host macOS versions before 27 (see [apple/swift-collections#733](https://github.com/apple/swift-collections/issues/733)). The `ponytail:` comment in `Package.swift` marks this pin for removal once the development machine's OS is upgraded past that gap. 🟢

## Forward-looking items explicitly out of scope for v1 (stated in the design prompt)

- HTTP/2 over TLS (`NIOHTTP2`) — design must not block adding it later, but is not implemented. 🟢
- TypeScript type generation / `openapi-typescript` — JS-only frontend by explicit constraint. 🟢

## Review Checklist

- Completeness
  - [x] Delivery history reconstructed from the generation prompt's own log
- Accuracy
  - [x] No speculative phases; every entry traceable to a source document
- Consistency
  - [x] Aligned with [CHANGELOG.md](CHANGELOG.md) and [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
- TODO
  - [ ] Re-verify "Delivered" table if `swift build`/`swift test` is re-run and results differ
- Missing information
  - [ ] No independent confirmation that tests still pass today — the 11/11 and 7/7 figures come from the prompt's own log, not a fresh test run in this review
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟡 Inferred from the generation prompt's self-reported log, not independently re-run in this review
