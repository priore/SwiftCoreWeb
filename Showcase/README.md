# SwiftCoreWeb Showcase

Free for noncommercial use under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0); commercial use requires a separate commercialization agreement with the author. Source-available, not open-source. See `LICENSE` at the repository root.

This directory is a real, compilable set of Swift source files demonstrating every piece of SwiftCoreWeb end to end: a macro-based controller and closure Minimal API routes on one server, two authentication schemes, a `WKWebView`-hosted Vue frontend, SwiftUI lifecycle binding, and keep-awake. **It is not an Xcode project** — there is no `.xcodeproj` here — because the framework itself only ships as an SPM package; wiring these files into an app target is a five-minute manual step, below.

## Contents

```
Showcase/
├── README.md                    (this file)
├── Info.plist.snippet.xml       Required Info.plist keys (spec the concurrency/lifecycle/network watchdog design)
├── vite.config.js               Ready-to-copy Mode A dev-server config
└── ShowcaseApp/
    ├── Sources/
    │   ├── ShowcaseApp.swift        @main entry point
    │   ├── ShowcaseRootView.swift   WKWebView host + ScenePhase lifecycle binding
    │   ├── ShowcaseWebView.swift    WKWebView UIViewRepresentable wrapper
    │   ├── ShowcaseServer.swift     Builds the WebApplication: auth, middleware, routes
    │   └── Models.swift             Todo (@ApiModel) + TodoStore (DI service)
    ├── Controllers/
    │   └── TodoController.swift     @Controller macro-based routes
    └── www/
        └── index.html                Zero-build Vue page (the built-in Vue runtime design)
```

`scripts/deploy-to-device.mjs` (Mode B pusher) and `scripts/copy-dist-to-bundle.sh` (Mode C build phase) live at the repository root's `scripts/` directory, alongside the existing `scripts/update-vue.sh`.

## Wiring this into an Xcode project

1. Create a new iOS App target (SwiftUI lifecycle, iOS 15.0 minimum deployment target) in Xcode, or use an existing one.
2. Add the SwiftCoreWeb package: File > Add Package Dependencies… and point it at this repository (or a local path), then link the `SwiftCoreWeb` library to your app target. Do **not** link `SwiftCoreWebTesting` into the app target — that library is for test targets only.
3. Drag `Showcase/ShowcaseApp/Sources/*.swift` and `Showcase/ShowcaseApp/Controllers/*.swift` into your app target (checking "Copy items if needed" and your target's membership checkbox).
4. Add `Showcase/ShowcaseApp/www/` as a folder reference (blue folder icon, not a group) in "Copy Bundle Resources", or copy it into your Vue project's `dist/` output for Mode C — see below.
5. Merge `Info.plist.snippet.xml`'s keys into your target's Info.plist (Xcode's target > Info tab, or the raw file if you don't use `GENERATE_INFOPLIST_FILE`).
6. Build and run. The app starts the server, waits for its listener to bind, then shows a `WKWebView` pointed at `http://127.0.0.1:8080/`.

## What each file demonstrates

- **`ShowcaseServer.swift`** — the framework's full request pipeline assembled in one place: `.useExceptionHandler()`, `.useSecurityHeaders()`, `.useCors()`, `.useRequestLogging()`, two authentication schemes (`.jwt` and a `.custom("apiKey")` header scheme) via one `.useAuthentication(...)` call, `.useAuthorization()`, a macro-based controller (`mapControllers(TodoController.self)`), closure Minimal API routes and route groups (`mapGroup(...).requireAuthorization(...)`), `mapOpenApi()`, `mapSse(...)`, `mapWebSocket(...)`, and the Vue/SPA hosting split between DEBUG (`useDevDeploy` + `useSpa(root: .documents("www"))`, Mode B) and release (`useSpa(root: .bundle("dist"))`, Mode C).
- **`Controllers/TodoController.swift`** — `@Controller`/`@Get`/`@Post`/`@Delete` macro-based routing: path parameters (`{id:int}`), a JSON request body, DI-resolved services via the `Service<T>` parameter-binding wrapper, and `auth: .authenticated` / `auth: .roles(["admin"])` route metadata.
- **`Models.swift`** — `@ApiModel` on a `Codable` struct (compile-time OpenAPI schema, no reflection) and a simple lock-protected in-memory store registered with `builder.services.addSingleton { TodoStore() }`.
- **`ShowcaseWebView.swift`** — the `WKWebView` that loads the same-origin site the server just started, so its API calls need no CORS.
- **`ShowcaseRootView.swift`** — SwiftUI's `@Environment(\.scenePhase)` driving `stopAsync()`/`runAsync()` directly. The framework ships a UIKit-notifications lifecycle binding (`WebApplication.bindToLifecycle()`); this file is the SwiftUI-idiomatic alternative the framework's own documentation points to, since `ScenePhase` is a SwiftUI concern the core library does not need to depend on.
- **`ShowcaseApp.swift`** — builds the `WebApplication` once at process launch (in a `UIApplicationDelegateAdaptor`) so it exists before the first view appears.

Keep-awake (`builder.keepDeviceAwake(true)`) is on by default and shown explicitly in `ShowcaseServer.makeApplication()`; no extra code is needed to keep the device from auto-locking while the server runs in the foreground.

## Frontend development workflows (spec the frontend development workflows)

### Mode A — Vue on the Mac, API on the device (recommended)

Full HMR, zero framework code on the frontend side.

1. On the device, call `builder.listenOnAllInterfaces()` (and optionally `builder.advertise(name: "my-iphone")`) instead of the loopback-only default.
2. Copy `Showcase/vite.config.js` into your Vue project's root, and set `DEVICE_HOSTNAME` to your device's Bonjour name or LAN IP.
3. `npm run dev` — Vite opens on the Mac; every `/api/*`, `/openapi.json`, and `/ws/*` request proxies to the device.

### Mode B — Vue running on the device (DEBUG only)

`ShowcaseServer.makeApplication()` already calls `app.useDevDeploy(root: .documents("www"))` under `#if DEBUG`. On launch, the Xcode console prints a random deploy token. To push a build:

```sh
npm run build          # writes dist/
node ../scripts/deploy-to-device.mjs --host my-iphone.local --token <token-from-console>
```

The device writes the upload atomically to `Documents/www` and signals every connected `/__dev/livereload` client to reload. This entire code path does not exist in release builds — `useDevDeploy` is defined only inside `#if DEBUG`.

### Mode C — production

1. Build your Vue project: `npm run build` (writes `dist/`).
2. Add `scripts/copy-dist-to-bundle.sh` as a Run Script build phase on your app target, after "Copy Bundle Resources" (see the comment header in that script for the exact Xcode wiring, including Input/Output Files).
3. `ShowcaseServer.makeApplication()`'s release branch already calls `app.useSpa(root: .bundle("dist"))`.

## Auth quick reference

- **JWT**: `Authorization: Bearer <token>` signed with the HS256 secret written to the Keychain via `SecretStore.write("showcase-demo-signing-secret", forKey: "jwtSigningSecret")` in `ShowcaseServer.swift`. Issue a demo token with any JWT tool using that secret and `alg: HS256`.
- **API key**: `X-Api-Key: showcase-demo-key` — resolves a principal with the `admin` role, satisfying both `auth: .authenticated` and `auth: .roles(["admin"])` routes (e.g. `DELETE /api/todos/{id}`).

Both schemes are registered in one `.useAuthentication(.jwt(...), .custom("apiKey") { ... })` call; whichever one resolves a principal first wins, and `ctx.user?.scheme` (or `AuthRequirement.scheme("apiKey")` on a route) can require one specifically.
