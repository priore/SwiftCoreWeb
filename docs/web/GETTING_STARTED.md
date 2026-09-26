# Web: getting started

[← docs index](../README.md)

You are here if: you're serving pages/HTML/a frontend to a browser or WebView, not (only) JSON.
Read [Getting started](../GETTING_STARTED.md) and
[Routing and middleware](../ROUTING_AND_MIDDLEWARE.md) first if you haven't yet.

## Four ways to serve a page, simplest to most involved

**a) One static file, no build step**

```swift
app.useStaticFiles(root: .bundle("www")) // serves everything under www/ as-is
// GET /index.html -> www/index.html, GET /style.css -> www/style.css, etc.
```

**b) A single-page app (Vue/React/whatever), history-mode routing**

```swift
app.useStaticFiles(root: .bundle("www"))
app.useSpa(root: .bundle("www")) // any unmatched non-/api route -> www/index.html
```

`apiPrefix` defaults to `/api`, so `app.mapGet("/api/users", ...)` still resolves as an API route
instead of falling back to the SPA's `index.html`.

**c) Zero-build Vue, no separate frontend build at all**

```swift
app.useVue()                             // serves the bundled Vue 3 runtime at /_framework/vue.js
app.useStaticFiles(root: .bundle("www")) // your own www/index.html <script>-tags it in
```

**d) Server-rendered HTML with a model, no client-side framework**

```swift
app.useViews(root: .bundle("www")) // once, before any View(...) is returned

struct HomeModel: Encodable { let deviceName: String; let requestCount: Int }

app.mapGet("/") { _ in
    View("index.html", model: HomeModel(deviceName: "iPhone", requestCount: 42))
}
```

`www/index.html`:

```html
<!doctype html>
<html><body>
  <h1>[[ deviceName ]]</h1>
  <p>Requests served: [[ requestCount ]]</p>
</body></html>
```

Every `[[ name ]]` is looked up in that route's own model and HTML-escaped automatically;
`[[& name ]]` skips escaping for markup you already know is safe. `[[ ]]`-delimited on purpose, so
it never collides with Vue's own `{{ }}` syntax if the same page also loads Vue.

Any of the four can run at the same time on the same `WebApplication` — pick per-page, not per-app.

## Next

- [Basic examples](EXAMPLES_BASIC.md) — small, complete single-concept examples.
- [Advanced examples](EXAMPLES_ADVANCED.md) — multi-page sites, Vue, WebSocket/SSE.
- [Auth and security](AUTH_AND_SECURITY.md) — protecting pages, sessions, CORS.
