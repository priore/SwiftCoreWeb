# SwiftCoreWeb docs

[← project README](../README.md)

Full guide to SwiftCoreWeb, organized so a beginner can find "how do I do X" without reading the
whole library reference first. If you just want the fastest possible taste of the library, the
[project README](../README.md) has a one-screen Hello World — come here once you're ready to build
something real.

This index mirrors the folder structure: **Foundation** (shared by every app), then two parallel
tracks — **Web** (serving pages/UI) and **API** (serving JSON/REST) — then **Reference**. Both
tracks follow the same shape (Getting Started → Basic Examples → Advanced Examples → Auth &
Security), so once you know one track you already know how to navigate the other.

## Foundation

Read these first, regardless of whether you're building a web app, an API, or both on the same server.

- [Getting started](GETTING_STARTED.md) — install, Hello World, project layout, running the Showcase app.
- [Routing and middleware](ROUTING_AND_MIDDLEWARE.md) — Minimal API vs `@Controller`, route templates, parameter binding, the middleware pipeline.
- [Secrets and certificates](SECRETS_AND_CERTIFICATES.md) — generating JWT signing secrets and TLS certificates (self-signed and CA-issued), storing them in the Keychain.
- [Testing guide](TESTING_GUIDE.md) — testing routes, auth, and middleware with `TestHost`.
- [FAQ and troubleshooting](FAQ_AND_TROUBLESHOOTING.md) — the obvious questions, the "is X even possible on iOS" questions, and common gotchas.

## Web track — serving pages and UI

- [Getting started](web/GETTING_STARTED.md) — your first served page: static files, SPA hosting, server-rendered templates.
- [Basic examples](web/EXAMPLES_BASIC.md) — a static page, a form post, a server-rendered page with a model.
- [Advanced examples](web/EXAMPLES_ADVANCED.md) — a linked multi-page site, zero-build Vue, the full Vite workflow, WebSocket and SSE pages.
- [Auth and security](web/AUTH_AND_SECURITY.md) — protecting pages, cookies/sessions, CORS, security headers.
- [On-device dashboard guide](web/DASHBOARD_GUIDE.md) — the on-device dashboard course (`SwiftCoreWebDashboard`): a live console on the device's own screen for the server running on it.

*(Coming later, once the feature ships: a Live Pages guide covering Vue components wired to Swift event handlers.)*

## API track — serving JSON and REST

- [Getting started](api/GETTING_STARTED.md) — your first JSON route, `Results`, `ProblemDetails`.
- [Basic examples](api/EXAMPLES_BASIC.md) — a single GET/POST route, parameter binding from query/route/body.
- [Advanced examples](api/EXAMPLES_ADVANCED.md) — a full CRUD API: routes, `@ApiModel`, DI, rate limiting, OpenAPI docs, tested end to end.
- [Auth and security](api/AUTH_AND_SECURITY.md) — JWT, a custom API-key scheme, authorization policies, TLS on APIs.

## Reference

- [.NET naming table](DOTNET_MAPPING.md) — ASP.NET Core Minimal API → SwiftCoreWeb naming table, for developers coming from .NET.
