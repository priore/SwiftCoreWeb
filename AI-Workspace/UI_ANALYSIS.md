# UI Analysis

## Overview

SwiftCoreWeb (the core library, `Sources/SwiftCoreWeb/`) is a server-side framework, not a UI
framework. It has **no SwiftUI component library, no design tokens, and no native UI layer of its
own**. The repository's UI code lives in two places instead: the minimal `ShowcaseApp` sample and
the optional `SwiftCoreWebDashboard` product (used by the newer `HelloWorldApp` sample) — see
below. This document replaces an earlier draft that described a generic SwiftUI component system
(buttons, toggles, pickers, toast notifications, dark mode palette) — none of that exists in this
codebase; it was template content never checked against the source. 🟢

## Showcase App UI (`Showcase/ShowcaseApp/`)

`Showcase/ShowcaseApp/Sources/`:

| File | Role |
|---|---|
| `ShowcaseApp.swift` | App entry point. |
| `ShowcaseRootView.swift` | Single SwiftUI view: shows a `ProgressView` while starting, the `WKWebView` once the server is running, or an error view. Binds server start/stop to `ScenePhase` (`.active`/`.background`). |
| `ShowcaseWebView.swift` | `UIViewRepresentable` wrapper around `WKWebView`, pointed at `http://127.0.0.1:8080/`. |
| `ShowcaseServer.swift` | Configures and builds the `WebApplication` (port, controllers, middleware) used by the showcase. |
| `Models.swift`, `Controllers/TodoController.swift` | Example API model + one `@Controller` demonstrating macro routing. |
| `www/index.html` | Static HTML/Vue page served by the framework and rendered inside the `WKWebView`. |

That is the entire native UI surface of this sample: one status screen with three states (loading /
running / error) and one web view. There are no reusable SwiftUI components, no theming system, and
no custom view modifiers defined anywhere in `Sources/SwiftCoreWeb/` or `Showcase/ShowcaseApp/`. 🟢

## On-device Dashboard UI (`Sources/SwiftCoreWebDashboard/`, used by `Showcase/HelloWorldApp/`)

A second, newer showcase (`Showcase/HelloWorldApp/`) replaces the `WKWebView` status screen above
with a full native SwiftUI dashboard — this is a real, reusable SwiftUI component library, but it
lives in its own opt-in SPM product (`SwiftCoreWebDashboard`), not in the core framework (see the
exception documented in [swift-style.md](../.claude/swift-style.md)). `HelloWorldRootView.swift`
shows `SwiftCoreWebDashboardView(app:)` full-screen once the server is running; there is no web view
in this showcase, `/` still serves plain HTML to browsers as before.

| Component | Role |
|---|---|
| `DashboardRootView.swift` | Switches between the two dashboard styles at runtime; style picker in the safe-area top. |
| `Views/MissionControl/` | Style A: dense NOC-style grid (tiles, sparklines, status LEDs). |
| `Views/NativeCards/` | Style B: iOS Health/Settings-style grouped cards, gauge rings. |
| `Views/Shared/` | `Sparkline`, `GaugeRing`, `QRCodeView`, `RequestLogView`, `HistoryView` — shared by both styles. |
| `DashboardModel.swift` | `@MainActor ObservableObject`; reads `app.metrics.snapshot()` + the device sampler, drives Start/Stop/Restart. |
| `DashboardStyle.swift` | Persists the chosen style in `UserDefaults`. |

Both styles read the same data (`DashboardModel`) and the same shared components; only tile layout
and visual language differ. 🟢 (`Sources/SwiftCoreWebDashboard/`,
`Showcase/HelloWorldApp/Sources/HelloWorldRootView.swift`)

## Web-Side UI (served content, not native)

The actual visual/interactive surface a user sees is whatever HTML/Vue page is served through `useStaticFiles()`/`useSpa()` and rendered in the `WKWebView` — this is standard web content (HTML/CSS/JS + Vue 3), not a native design system. The framework embeds the Vue 3 runtime (`vue.esm-browser.prod.js`) as a package resource and serves it at `/_framework/vue.js` for zero-build pages. A server-side `[[ ]]`-delimited template engine can inject data into HTML before it's served, without touching Vue's own `{{ }}` bindings. 🟢 (`Sources/SwiftCoreWeb/VueRuntime.swift`, `TemplateEngine.swift`, `Showcase/ShowcaseApp/www/index.html`)

Any design system, component library, or token set for that web content would belong to the specific app/site built on top of SwiftCoreWeb (e.g. a Vue project's own CSS), not to this framework — SwiftCoreWeb only serves the files. 🟢

## What was removed from the previous version of this document

The previous draft claimed: SwiftUI component architecture with reactive/Combine patterns, a native button/input/navigation/data-display/feedback component catalog, Apple HIG "Soft UI" visual language, dynamic type/VoiceOver/high-contrast support, and theme customization (light/dark, typography, spacing systems) as framework features. None of these are implemented anywhere in `Sources/SwiftCoreWeb/`, `Sources/SwiftCoreWebMacros/`, or `Sources/SwiftCoreWebTesting/`. They read as generic mobile-app boilerplate, not analysis of this project, and have been dropped rather than left unverified. The corresponding `DESIGN_SYSTEM.md`, `DESIGN_TOKENS.md`, and `COMPONENT_LIBRARY.md` documents were removed entirely (no real subject matter) — see [WORKSPACE_MANIFEST.md](WORKSPACE_MANIFEST.md#removed-from-this-manifest).

## Review Checklist

- Completeness
  - [x] Actual UI surface (showcase) documented
  - [x] Web-served content path documented
  - [x] Fictional prior content identified and removed
- Accuracy
  - [x] Verified against `Showcase/ShowcaseApp/Sources/*.swift` (2026-09-24)
- Consistency
  - [x] Aligned with [ARCHITECTURE.md](architecture/ARCHITECTURE.md) "What this document intentionally omits"
- TODO
  - [ ] Update if Showcase gains additional views/controls
- Missing information
  - [ ] None — scope is intentionally small because the real surface is small
- Open questions
  - [ ] None at this time
- Confidence level
  - [x] 🟢 Confirmed by the code
