# HelloWorldApp

Free for noncommercial use under the [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/); commercial use requires a separate license from the author. Source-available, not open-source. See `LICENSE` at the repository root.

Minimal, runnable SwiftCoreWeb sample — unlike `Showcase/ShowcaseApp` (source files only, no `.xcodeproj`), this one is a real Xcode project you can open and press Run.

Serves:
- `http://[device-ip]:8080/` — Vue 3 page (`www/index.html`, rendered with the framework's built-in Vue runtime, no npm/build step) showing current date/time (client-side) and device name (fetched from the API below)
- `http://[device-ip]:8080/api/device-name` — JSON: `{"deviceName": "..."}`

## Run

```sh
open HelloWorldApp.xcodeproj
```

Press Run (simulator or device). The app starts the server, waits for it to bind, then shows the page in a `WKWebView`. From a browser on the same network (or the simulator's host Mac), open `http://127.0.0.1:8080/` or the device's LAN IP.

Regenerate the project after editing `project.yml` (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen), `brew install xcodegen`):

```sh
xcodegen generate
```

## Structure

```
HelloWorldApp/
├── project.yml              XcodeGen spec — generates HelloWorldApp.xcodeproj
├── Sources/
│   ├── HelloWorldApp.swift      @main entry point
│   ├── HelloWorldServer.swift   Builds the WebApplication: one API route + static hosting
│   └── HelloWorldRootView.swift WKWebView host + ScenePhase lifecycle binding
└── www/
    └── index.html            The served page — a separate static file, not a Swift string
```

`HelloWorldServer.swift` never reads or returns HTML from Swift code: `app.useVue()` serves the framework's Vue 3 runtime at `/_framework/vue.js` + `/_framework/api.js`, and `app.useSpa(root: .bundle("www"))` hands file serving (streaming, `ETag`, `Range`, MIME types) to the framework's own static-file hosting — exactly like `ShowcaseServer.swift`'s release-mode Vue hosting. `www/index.html` renders with `createApp`/`{{ }}` bindings, no manual DOM manipulation and no extra frontend dependency (jQuery etc.) needed.

See `Showcase/ShowcaseApp` for the full-featured showcase (auth, controllers, WebSockets, SSE, Vue frontend) this sample intentionally leaves out.
