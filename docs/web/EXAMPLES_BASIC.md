# Web track: basic examples

[← docs index](../README.md)

You are here if: you want a small, complete, copy-pasteable example — one concept each, no extra
moving parts.

## A static page

```swift
app.useStaticFiles(root: .bundle("www"))
```

```
www/
└── index.html
```

`GET /index.html` returns the file as-is. No Swift code touches its content.

## A form post

```swift
struct ContactForm: Decodable, Sendable {
    let name: String
    let message: String
}

app.mapPost("/contact") { (form: ContactForm) in
    // handle it (save, email, whatever)
    Results.redirect("/thanks.html")
}
```

```html
<form method="post" action="/contact">
  <input name="name">
  <textarea name="message"></textarea>
  <button type="submit">Send</button>
</form>
```

A non-primitive `Decodable` parameter on `POST` binds from the JSON body automatically — see
[Routing and middleware](../ROUTING_AND_MIDDLEWARE.md) for the full binding order. For a
plain HTML `<form>` (URL-encoded, not JSON), use the `Form` parameter-binding wrapper instead.

## A server-rendered page with a model

```swift
app.useViews(root: .bundle("www"))

struct GreetingModel: Encodable {
    let visitorName: String
}

app.mapGet("/hello/{name}") { (name: String) in
    View("hello.html", model: GreetingModel(visitorName: name))
}
```

```html
<!-- www/hello.html -->
<!doctype html>
<html><body><h1>Hello, [[ visitorName ]]!</h1></body></html>
```

`GET /hello/Mario` renders `Hello, Mario!`. The model type is different per route — no shared layout
system, no view inheritance, just one model in, one page out.

## Next

[Advanced examples](EXAMPLES_ADVANCED.md) builds on these with multi-page navigation, Vue, and
realtime routes.
