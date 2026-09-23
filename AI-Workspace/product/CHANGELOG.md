# Changelog

## Overview

This replaces a previous draft that invented four semantic-version releases (v0.1.0 through v0.4.0, including fictional "Android platform support" and "WebAssembly integration"). The project has no version tags or release history — it carries no version number anywhere in `Package.swift` or the repository. 🟢 Below is the real, single-baseline delivery history, reconstructed from the generation log in [framework_http_server_prompt.md](../Prompts/framework_http_server_prompt.md) and the initial git commit.

## Baseline

### Initial commit (`27fe071`)

The full framework delivered in one baseline: `SwiftCoreWeb` core (server engine, routing, middleware, auth, rate limiting, static/SPA hosting, template engine, SSE, WebSocket, OpenAPI), `SwiftCoreWebMacros` compiler plugin, `SwiftCoreWebTesting`, full test suite, and the Showcase app. See [ROADMAP.md](ROADMAP.md) for the 6-part delivery breakdown recorded in the generation prompt. 🟢

Notable fixes folded into this baseline before it was committed (root-caused, not patched around — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for detail):
- `Encodable` DTO routes returning empty `204` instead of `200` JSON.
- Missing `import CompilerPluginSupport` breaking the macro target build.
- `ContinuousClock` (iOS 16+) replaced with `DispatchTime` for the iOS 15 floor.
- Pre-GA `NIOAsyncChannel` member names and an `NSLock` used from async context.
- `swift-collections` pinned to `exact: "1.6.0"` to work around a missing runtime symbol on older host OSes.

## Versioning Strategy

None adopted yet — there is no version number in `Package.swift` and no git tags exist (`git log` shows a single commit). This section will be filled in if/when the project adopts semantic versioning. 🟢

## Review Checklist

- Completeness
  - [x] Reflects actual single-baseline history, not invented releases
- Accuracy
  - [x] Verified against `git log` (single commit) and the generation prompt's log (2026-09-24)
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
