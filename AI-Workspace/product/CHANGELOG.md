# Changelog

## Overview

This replaces a previous draft that invented four semantic-version releases (v0.1.0 through v0.4.0, including fictional "Android platform support" and "WebAssembly integration"). `Package.swift` itself still carries no version number, but the repository now has a real git tag, `v1.0.0`, on the initial baseline commit. 🟢 Below is the real delivery history, reconstructed from the generation log in [framework_http_server_prompt.md](../Prompts/framework_http_server_prompt.md), the initial git commit, and `git tag`.

## v1.0.0 (`27fe071`, tagged at `4598de9`)

The full framework delivered in one baseline: `SwiftCoreWeb` core (server engine, routing, middleware, auth, rate limiting, static/SPA hosting, template engine, SSE, WebSocket, OpenAPI), `SwiftCoreWebMacros` compiler plugin, `SwiftCoreWebTesting`, full test suite, and the Showcase app. See [ROADMAP.md](ROADMAP.md) for the 6-part delivery breakdown recorded in the generation prompt. 🟢

Notable fixes folded into this baseline before it was committed (root-caused, not patched around — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for detail):
- `Encodable` DTO routes returning empty `204` instead of `200` JSON.
- Missing `import CompilerPluginSupport` breaking the macro target build.
- `ContinuousClock` (iOS 16+) replaced with `DispatchTime` for the iOS 15 floor.
- Pre-GA `NIOAsyncChannel` member names and an `NSLock` used from async context.
- `swift-collections` pinned to `exact: "1.6.0"` to work around a missing runtime symbol on older host OSes.

## Unreleased (since `v1.0.0`, not yet tagged)

### Live Pages (`Page`, `mapPage`, `usePages`, `/_framework/live.js`)

Server-rendered Vue pages driven by Swift state, Livewire/Blazor-Server-style: a template compiled
on the server (JavaScriptCore + vendored `@vue/compiler-dom`, no `unsafe-eval` needed under
`useSecurityHeaders()`), state round-tripped in an HMAC-signed snapshot, form binding with
field-level errors, antiforgery cookie, and a small client (`/_framework/live.js`) handling the
event queue/debounce/redirect. See [ARCHITECTURE.md](../architecture/ARCHITECTURE.md#live-pages-server-rendered-vue-livewire-style),
[DECISIONS.md#d007](DECISIONS.md#d007-live-pages-templates-precompiled-server-side-via-javascriptcore-snapshot-signed-with-a-per-process-hmac-key),
and `docs/web/LIVE_PAGES_GUIDE.md`. 🟢

## Versioning Strategy

Git tags (`v1.0.0` on the initial commit), no version number in `Package.swift` (SwiftPM resolves
this package by branch/commit, not by manifest version). Entries under "Unreleased" move under a new
`## vX.Y.Z (<commit>)` heading here once that commit is actually tagged — never before. 🟢

## Review Checklist

- Completeness
  - [x] Reflects actual tag/commit history, not invented releases
- Accuracy
  - [x] Verified against `git log`, `git tag` (2026-09-26) and the generation prompt's log (2026-09-24)
- Consistency
  - [x] Aligned with [ROADMAP.md](ROADMAP.md) and [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
- TODO
  - [ ] Add entries only when a real commit/tag/release exists
- Missing information
  - [ ] None at this time
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code and git history
