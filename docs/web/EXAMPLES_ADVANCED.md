# Web: advanced examples

[← docs index](../README.md)

You are here if: [Basic examples](EXAMPLES_BASIC.md) felt too small — this is multi-page sites,
Vue, realtime updates.

## A linked multi-page site, each page with its own model

Register the view root once, then return `View(_:model:)` from as many routes as you like; each
gets its own model type — no shared layout system, no view inheritance.

```swift
app.useViews(root: .bundle("www")) // once, before any View(...) is returned

struct HomeModel: Encodable {
    let deviceName: String
    let requestCount: Int
}

struct DeviceDetailModel: Encodable {
    let deviceName: String
    let systemVersion: String
    let batteryPercent: Int
}

app.mapGet("/") { _ in
    View("index.html", model: HomeModel(
        deviceName: UIDevice.current.name,
        requestCount: app.metrics.snapshot().totalRequests
    ))
}

app.mapGet("/device") { _ in
    View("device.html", model: DeviceDetailModel(
        deviceName: UIDevice.current.name,
        systemVersion: UIDevice.current.systemVersion,
        batteryPercent: Int(UIDevice.current.batteryLevel * 100)
    ))
}
```

`www/index.html` — links to the second page, no query string needed since `/device` reads its own
model server-side:

```html
<!doctype html>
<html><body>
  <h1>[[ deviceName ]]</h1>
  <p>Requests served: [[ requestCount ]]</p>
  <a href="/device">Device details</a>
</body></html>
```

`www/device.html` — a different template, different model, navigated to by the link above:

```html
<!doctype html>
<html><body>
  <h1>[[ deviceName ]]</h1>
  <p>iOS [[ systemVersion ]] — battery [[ batteryPercent ]]%</p>
  <a href="/">&larr; Back</a>
</body></html>
```

## Hydrating client-side JS with the same model (`injectState`)

If the page also runs Vue (or any client JS) and needs the server's model as a JS object rather than
just interpolated text, `injectState(_:)` JSON-encodes and escapes the value into a ready-to-embed
`<script>window.__INITIAL_STATE__=...</script>` tag:

```swift
app.mapGet("/") { _ in
    let stateScript = try injectState(HomeModel(deviceName: "iPhone", requestCount: 42))
    let html = """
    <!doctype html><html><body>
    <div id="app"></div>
    \(stateScript)
    <script type="module" src="/app.js"></script>
    </body></html>
    """
    var headers = HttpHeaders()
    headers["Content-Type"] = "text/html; charset=utf-8"
    return HttpResult(HttpResponse(headers: headers, body: .text(html)))
}
```

`window.__INITIAL_STATE__` is then available to your client JS as a plain object — the same
escaping the framework's own template engine uses internally, so untrusted model content can't
break out of the `<script>` tag.

## Zero-build Vue

```swift
app.useVue()                             // serves the Vue 3 runtime at /_framework/vue.js
app.useStaticFiles(root: .bundle("www")) // your own www/index.html <script>-tags it in
```

```html
<!-- www/index.html -->
<script src="/_framework/vue.js"></script>
<div id="app">{{ message }}</div>
<script>
  Vue.createApp({ data: () => ({ message: "Hello from Vue!" }) }).mount("#app")
</script>
```

No build step, fully offline. For a larger app, use the standard Vite + `.vue` workflow instead —
see `Showcase/README.md` for both Mode A (Vite on the Mac, API on the device, full HMR) and Mode B
(on-device dev-deploy with live reload) end to end, plus Mode C (a production Xcode build phase
that copies `dist/` into the bundle).

## Realtime: Server-Sent Events

```swift
app.mapSse("/events") { writer in
    for i in 0..<5 {
        try await writer.send("tick \(i)")
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
}
```

Compatible with the browser's `EventSource` — no client dependency:

```html
<script>
  new EventSource("/events").onmessage = (e) => console.log(e.data)
</script>
```

## Realtime: WebSocket

```swift
app.mapWebSocket("/ws") { socket in
    for try await message in socket.messages() {
        if case .text(let text) = message {
            try await socket.send("echo: \(text)")
        }
    }
}
```

## Next

- [Auth and security](AUTH_AND_SECURITY.md) — protecting the pages built above.
- [On-device dashboard guide](DASHBOARD_GUIDE.md) — a native on-device screen alongside these web routes.

Once Live Pages ships, a Live Pages guide (in this same folder) will cover full Swift-driven
event round-trips for every Vue component (`v-model`, `@click`, validation, session state) — the
model where a click in the browser runs Swift on the server and updates the page, with no
client-side JS to write.
