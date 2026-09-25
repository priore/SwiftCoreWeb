# SwiftCoreWeb docs

[← project README](../README.md)

Full guide to SwiftCoreWeb, organized so a beginner can find "how do I do X" without reading the
whole library reference first. If you just want the fastest possible taste of the library, the root
[`README.md`](../README.md) has a one-screen Hello World — come here once you're ready to build
something real.

This index mirrors the folder structure: **Foundation** (shared by every app), then two parallel
tracks — **Web** (serving pages/UI) and **API** (serving JSON/REST) — then **Reference**. Both
tracks follow the same shape (Getting Started → Basic Examples → Advanced Examples → Auth &
Security), so once you know one track you already know how to navigate the other.

## Foundation

Read these first, regardless of whether you're building a web app, an API, or both on the same server.

- [GETTING_STARTED.md](GETTING_STARTED.md) — install, Hello World, project layout, running the Showcase app.
- [ROUTING_AND_MIDDLEWARE.md](ROUTING_AND_MIDDLEWARE.md) — Minimal API vs `@Controller`, route templates, parameter binding, the middleware pipeline.
- [SECRETS_AND_CERTIFICATES.md](SECRETS_AND_CERTIFICATES.md) — generating JWT signing secrets and TLS certificates (self-signed and CA-issued), storing them in the Keychain.
- [TESTING_GUIDE.md](TESTING_GUIDE.md) — testing routes, auth, and middleware with `TestHost`.
- [FAQ_AND_TROUBLESHOOTING.md](FAQ_AND_TROUBLESHOOTING.md) — the obvious questions, the "is X even possible on iOS" questions, and common gotchas.

## Web track — serving pages and UI

- [web/GETTING_STARTED.md](web/GETTING_STARTED.md) — your first served page: static files, SPA hosting, server-rendered templates.
- [web/EXAMPLES_BASIC.md](web/EXAMPLES_BASIC.md) — a static page, a form post, a server-rendered page with a model.
- [web/EXAMPLES_ADVANCED.md](web/EXAMPLES_ADVANCED.md) — a linked multi-page site, zero-build Vue, the full Vite workflow, WebSocket and SSE pages.
- [web/AUTH_AND_SECURITY.md](web/AUTH_AND_SECURITY.md) — protecting pages, cookies/sessions, CORS, security headers.
- [web/DASHBOARD_GUIDE.md](web/DASHBOARD_GUIDE.md) — the on-device dashboard course (`SwiftCoreWebDashboard`): a live console on the device's own screen for the server running on it.

*(Coming later, once the feature ships: `web/LIVE_PAGES_GUIDE.md`, Vue components wired to Swift event handlers.)*

## API track — serving JSON and REST

- [api/GETTING_STARTED.md](api/GETTING_STARTED.md) — your first JSON route, `Results`, `ProblemDetails`.
- [api/EXAMPLES_BASIC.md](api/EXAMPLES_BASIC.md) — a single GET/POST route, parameter binding from query/route/body.
- [api/EXAMPLES_ADVANCED.md](api/EXAMPLES_ADVANCED.md) — a full CRUD API: routes, `@ApiModel`, DI, rate limiting, OpenAPI docs, tested end to end.
- [api/AUTH_AND_SECURITY.md](api/AUTH_AND_SECURITY.md) — JWT, a custom API-key scheme, authorization policies, TLS on APIs.

## Reference

- [DOTNET_MAPPING.md](DOTNET_MAPPING.md) — ASP.NET Core Minimal API → SwiftCoreWeb naming table, for developers coming from .NET.

## Keeping this wiki up to date

Adding a feature that touches Web or API surface? See [`.claude/rules/docs-maintenance.md`](../.claude/rules/docs-maintenance.md) for where it belongs and how to keep the two tracks symmetric.

This folder is also mirrored to the repository's GitHub Wiki automatically (`.github/workflows/wiki-sync.yml`) — edit the files here, never on the wiki directly.
