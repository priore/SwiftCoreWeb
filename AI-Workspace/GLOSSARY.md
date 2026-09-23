# Glossary

Key terms and concepts used throughout the project and this Knowledge Base.

| Term | Meaning |
|---|---|
| **SwiftCoreWeb** | The core SPM library target: server engine, routing, middleware, hosting. See [ARCHITECTURE.md](architecture/ARCHITECTURE.md). |
| **SwiftCoreWebMacros** | Compiler-plugin target (SwiftSyntax) implementing `@Controller`, `@Get`/`@Post`/etc., `@ApiModel`. |
| **SwiftCoreWebTesting** | Library target exposing `TestHost`, an in-memory pipeline runner used by tests. |
| **NIOTransportServices (NIOTS)** | SwiftNIO's `Network.framework`-backed transport; the sole network stack for HTTP, HTTPS and WebSocket in this project. |
| **`WebApplicationBuilder`** | Fluent builder (`WebApplication.createBuilder()`) configuring port, TLS, limits, services, environment before `.build()`. |
| **`WebApplication`** | The built, runnable server (`runAsync()`, `stopAsync(timeout:)`). |
| **Zero Runtime Reflection** | Design constraint: routing is generated at compile time by macros; `Mirror` is never used. |
| **`@Controller`** | Attached member+extension macro generating `registerRoutes(into:)` and `RouteProvider` conformance — the only macro that generates registration code. |
| **Method marker macros** | `@Get`, `@Post`, `@Put`, `@Patch`, `@Delete`, `@Head`, `@Options`, `@Route` — peer macros that validate and emit no code themselves. |
| **`HttpContext`** | Per-request abstraction over method, path, headers, body, `ctx.user`, `ctx.items`, `ctx.services`. |
| **`HttpResult` / `Results`** | Typed response helpers (`.ok`, `.created`, `.notFound`, etc.) returned from handlers. |
| **ProblemDetails** | RFC 9457 JSON error format returned by the exception-handler middleware. |
| **`RateLimiter`** | Actor implementing a token bucket per client IP; runs before the middleware pipeline (early-gate protection). |
| **Showcase app** | The example iOS app under `Showcase/ShowcaseApp/` demonstrating the framework; not an SPM library target. |
| **PolyForm Noncommercial 1.0.0** | The project's license: source-available, free for noncommercial use, not OSI-approved open-source — never call this project "open-source". |
| **🟢 / 🟡 / 🔴** | Confidence markers used throughout this Knowledge Base: confirmed by code / inferred / hypothesis (see [BOOTSTRAP.md](BOOTSTRAP.md)). |

## Review Checklist

- Completeness
  - [x] Core terms from ARCHITECTURE.md, PROJECT_ANALYSIS.md, DECISIONS.md covered
- Accuracy
  - [x] Definitions verified against the code (2026-09-24)
- Consistency
  - [x] Formatting is consistent with other documents
- TODO
  - [ ] Add terms as new documents are generated
- Missing information
  - [ ] None at this time
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code
