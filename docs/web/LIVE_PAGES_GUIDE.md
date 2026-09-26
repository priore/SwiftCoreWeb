# Web: Live Pages guide

[← docs index](../README.md)

You are here if: you want a page where a click in the browser runs Swift on the server and updates
the page — no client-side JS to write, no DOM code, one Vue template per page.

## The model, in three rules

1. **`form`** = whatever the user edits, bound to components with `v-model="form.x"`. It arrives in
   Swift already typed (`Bool`, `Int`, `[String]`, …). It's user input — validate it.
2. **Everything else** on the page struct is server state: it survives across events, the browser can
   see it (used to render) but can't modify it (the snapshot is signed). No secrets in page state.
3. **`$swift('name')`** in the template calls `onEvent("name")` in Swift. Change state and the page
   re-renders; or `return .redirect("/elsewhere")` to navigate away.

## Full example

```swift
struct OrderPage: Page {
    static let template = "order.html"
    static let title = "New order"

    struct Form: Codable, Sendable {
        var name = ""; var qty: Int? = 1; var country = ""; var city = ""
        var express = false; var payment = "card"; var extras: [String] = []
        var notes = ""; var search = ""
    }
    var form = Form()
    var countries: [Choice] = [Choice("IT", "Italy"), Choice("FR", "France")]
    var cities: [Choice] = []
    var results: [String] = []
    var total = 0.0

    mutating func onLoad(_ ctx: PageContext) async throws -> PageAction? {
        if !ctx.isPostBack { form.name = ctx.session.get(String.self, "lastName") ?? "" }
        return nil
    }

    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction {
        switch event {
        case "country":
            cities = await ctx.http.services.get(GeoService.self).cities(form.country)
            form.city = ""
        case "qty", "express":
            total = Double(form.qty ?? 0) * (form.express ? 12 : 9)
        case "search":
            results = await ctx.http.services.get(Catalog.self).find(form.search)
        case "save":
            if form.name.isEmpty { ctx.errors["name"] = "Name is required" }
            guard ctx.isValid else { return .render }
            ctx.session.set(form.name, "lastName")
            return .redirect("/orders/done")
        default: break
        }
        return .render
    }
}

app.useVue()
app.useSession()
app.usePages(root: .bundle("Views"))      // a folder NOT served as static files
app.mapPage("/orders/new", OrderPage.self)
```

`Views/order.html` — a Vue template only, no `<script>`:

```html
<input v-model="form.name" @change="$swift('name')">
<span v-if="errors.name" class="err">{{ errors.name }}</span>

<input type="number" v-model.number="form.qty" @change="$swift('qty')">

<select v-model="form.country" @change="$swift('country')">
  <option v-for="c in countries" :value="c.value">{{ c.label }}</option>
</select>
<select v-model="form.city" :disabled="cities.length === 0">
  <option v-for="c in cities" :value="c.value">{{ c.label }}</option>
</select>

<label><input type="checkbox" v-model="form.express" @change="$swift('express')"> Express</label>
<label><input type="radio" v-model="form.payment" value="card"> Card</label>
<label><input type="radio" v-model="form.payment" value="cash"> Cash</label>
<label v-for="x in ['gift','insurance']"><input type="checkbox" v-model="form.extras" :value="x"> {{ x }}</label>

<input v-model="form.search" @input="$swift('search', { debounce: 300 })">
<ul><li v-for="r in results">{{ r }}</li></ul>

<textarea v-model="form.notes" v-show="form.express"></textarea>   <!-- client-only, no round-trip -->
<p>Total: {{ total }}</p>
<button @click="$swift('save')" :disabled="$live.busy">Save</button>
```

## Component catalog → event → Swift

| Component | `v-model` | Type in `Form` | Typical event |
|---|---|---|---|
| text/email/password/tel/url/date/time/color input | `v-model` | `String` | `@change`, `@input` + `debounce`, `@keyup.enter`, `@blur` |
| number/range input | `v-model.number` | `Int?` / `Double?` (empty field = `""` → `nil`) | `@change` |
| textarea | `v-model` | `String` | `@change` / `@input` + `debounce` |
| single checkbox | `v-model` | `Bool` | `@change` |
| checkbox group / `select multiple` | `v-model` (array) | `[String]` | `@change` |
| radio group | `v-model` | `String` | `@change` |
| select | `v-model` | `String` / `Int` | `@change` |
| button / any element | — | — | `@click`, `@dblclick`, … any DOM event |
| Swift → components | values (`form`), lists (`v-for` over state), `:disabled`, `v-if`/`v-show`, `:class`, errors (`errors.x`), `.redirect` | | |

`$swift(event, { debounce?: ms, args?: [...] })`; `$live.busy` = a request is in flight.

## Protocol details (for when you need to know what's actually happening)

- **Precompilation, no `eval` in the browser.** `useSecurityHeaders()` sets `default-src 'self'`,
  which blocks Vue's runtime template compiler (`Function("Vue", code)`). Templates are instead
  compiled once on the server (`VueTemplateCompiler`, JavaScriptCore + vendored
  `@vue/compiler-dom`) and served as an external classic script at `GET /_live/<page>.js` —
  same-origin, no `unsafe-eval` needed. Cached per template; recompiled on `mtime` change only in
  `.development`.
- **Snapshot.** A JSON string `{ path, af, page }` plus an HMAC-SHA256 checksum, signed with a
  per-process key. The client round-trips the snapshot string unchanged and only `JSON.parse`s it to
  render — no client-side duplication of state. A mismatched path, antiforgery token, or checksum is
  a `400`. `// ponytail: per-process key, pages reload after a server restart`.
- **Antiforgery.** An `__scw_af` cookie (32 random bytes, `HttpOnly; SameSite=Lax`, `+Secure` under
  TLS) minted on first `GET` if absent. The `POST` event endpoint also only accepts
  `application/json`, so a cross-site form post can't hit it without a CORS preflight.
  `Content-Type` that isn't JSON → `415`.
- **Form binding.** The snapshot's `form` is overlaid with whatever keys the client sent, then
  decoded. If decoding the whole thing fails, each key is retried individually: a key that still
  won't convert keeps its previous value and lands in `ctx.errors[key]` — never a `400` for bad user
  input (same idea as ASP.NET's `ModelState`).
- **Outcomes.** `.render` → a new snapshot; `.redirect(url)` → `{ redirect }` (the client navigates
  with `location.assign`); `.result(...)` is an escape hatch (any `HttpResultConvertible`, unchanged).
  `onLoad` returning `.redirect` on a `GET` becomes a real `302`.
- **Client (`/_framework/live.js`).** One request at a time; events fired while one is in flight are
  queued and sent with the latest `form`; `debounce` is tracked per event name. On a response, every
  non-`form` field is applied; a `form` field is only overwritten if the user hasn't retyped it since
  it was sent — no lost keystrokes. A `400` (expired/invalid snapshot, e.g. after a server restart)
  triggers `location.reload()`; other errors fire a `live:error` event on `document`.

## Out of scope

File upload, shared layouts, nested components (one page = one component), server push (possible
later via the existing `mapSse`), a `@Page` macro. See
`AI-Workspace/Plans/LIVE_PAGES_PLAN.md` for the full design log.

## Next

- [Auth and security](AUTH_AND_SECURITY.md) — the same `useSession()`/cookie mechanics used above,
  in more depth.
- [FAQ](../FAQ_AND_TROUBLESHOOTING.md) — Live Pages requires JavaScript; state is visible to the
  client (not secret); sessions are in-memory, single-process.
