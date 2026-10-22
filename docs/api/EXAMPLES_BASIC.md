# API: basic examples

[← docs index](../README.md)

You are here if: you want a small, complete, copy-pasteable example — one concept each.

## GET with a route parameter

```swift
app.mapGet("/api/users/{id:int}") { (id: Int) in
    User(id: id, name: "Mario")
}
```

A name matching a route placeholder (`{id:int}` ↔ parameter `id`) binds from the path automatically.

## GET with a query parameter

```swift
app.mapGet("/api/search") { (q: String, limit: Int?) in
    // GET /api/search?q=swift&limit=10
    ["result for \(q)"]
}
```

A primitive or optional primitive parameter with no matching route placeholder binds from the query
string. `limit` is optional (`Int?`) — missing from the URL means `nil`, not an error.

## GET with the `Query<T>`/`Header<T>` wrappers, on a `@Controller` method

Only `@Controller` methods can use these — the macro reads the wire name straight from the Swift
parameter's own external label, so it must be a declared function parameter, not a closure
parameter:

```swift
@Get("/search")
func search(q: Query<String>) async throws -> [String] {
    ["result for \(q.wrappedValue ?? "")"]
}
```

`GET /api/search?q=swift` binds `q`. On a Minimal API closure (`mapGet`/`mapPost`), a plain optional
primitive parameter already binds from the query string by name convention (see the first example
above) — that covers the common case without needing the wrapper at all.

## POST with a JSON body

```swift
struct CreateUserRequest: Decodable, Sendable {
    let name: String
    let email: String
}

app.mapPost("/api/users") { (request: CreateUserRequest) in
    Results.created(location: "/api/users/1", User(id: 1, name: request.name))
}
```

A non-primitive `Decodable` parameter on `POST`/`PUT`/`PATCH` binds from the JSON body
automatically — no explicit `Content-Type` check, no manual decoding.

## POST with a form or a file upload

```swift
@Post("/avatars")
func upload(form: Form) async throws -> String {
    guard let avatar = form.files.first else { throw HttpError(.badRequest, "Missing file") }
    // Move it before the handler returns: temporaryPath is deleted after the response.
    try avatar.move(to: URL(fileURLWithPath: "/path/to/\(UUID().uuidString)"))
    return "\(form.fields["title"] ?? "untitled"): \(avatar.fileName), \(avatar.sizeInBytes) bytes"
}
```

A `Form` parameter binds `multipart/form-data` (fields and files) and
`application/x-www-form-urlencoded` (fields only); any other `Content-Type` is a `400`. The whole
body is buffered in RAM, so uploads are limited by `maxRequestBodySize` — or by a per-route limit, see below —
unless the route spools to disk (see "A very large upload"). `fileName` is the client's filename, for display only — never build
a path from it. `avatar.move(to:)` replaces an existing destination; `try avatar.data()` reads the
upload into memory instead.

## A raw binary upload

```swift
app.mapGroup("/api").maxRequestBodySize(20_000_000).mapPut("/avatar") { ctx in
    // Content-Type: application/octet-stream — the bytes arrive untouched in ctx.request.body.
    try ctx.request.body.write(to: avatarURL)
    return Results.noContent()
}
```

## A very large upload

A backup of a few hundred MB must not sit in memory. `spoolBodyToDisk` streams the request body to a temporary file;
the `Form` is then parsed from that file in blocks, with the same `Form` / `UploadedFile` API as above:

```swift
@Post("/backup", maxRequestBodySize: 500_000_000, spoolBodyToDisk: true)
func backup(form: Form) async throws -> String {
    guard let backup = form.files.first else { throw HttpError(.badRequest, "Missing file") }
    try backup.move(to: backupsDirectory.appendingPathComponent(UUID().uuidString))   // otherwise deleted after the response
    return "\(backup.sizeInBytes) bytes"
}

app.mapPut("/restore", maxRequestBodySize: 500_000_000, spoolBodyToDisk: true) { ctx in
    // Content-Type: application/octet-stream — no Form: the whole body is the file ctx.request.bodyFile (request.body is empty).
    guard let file = ctx.request.bodyFile else { throw HttpError(.badRequest, "Missing body") }
    try FileManager.default.moveItem(at: file, to: restoreURL)   // or just read it
    return Results.noContent()
}
```

Over `maxRequestBodySize` the answer is `413` and the partial file is deleted. Text fields of the form are limited to
1 MB in total. Details and guarantees: [Routing and middleware](../ROUTING_AND_MIDDLEWARE.md).

## A per-route body limit

```swift
let uploads = app.mapGroup("/files").maxRequestBodySize(50_000_000)   // this group only
uploads.mapPost("/import") { (form: Form) in /* ... */ }
```

The limit replaces the global `builder.maxRequestBodySize(_:)` (default 1 MB) for every route
registered on the group afterwards (nested groups inherit it); everything else keeps the global
value. It is applied twice: the server engine reads it from the request head and cuts the
connection before buffering more than the limit, and the dispatcher answers `413` for a body over
it (which is also what `TestHost` sees).

## Downloading bytes, a file, or a stream

```swift
app.mapGet("/api/report") { _ in
    Results.data(pdfBytes, contentType: "application/pdf", fileName: "relazione è.pdf")
}
app.mapGet("/api/backup") { _ in
    Results.file(backupPath, contentType: "application/zip", fileName: "backup.zip")   // streamed from disk
}
app.mapGet("/api/export") { _ in
    Results.stream(contentType: "text/csv", contentLength: csvSize, fileName: "export.csv") { sink in
        for chunk in csvChunks() { try await sink.write(chunk) }
    }
}
```

Good to know:

- `fileName` makes the browser save the file under that name. Any text is safe to pass: quotes, line breaks and `../` are removed. Use `disposition: .inline` to show the file in the browser instead.
- `contentLength` (streams) tells the client the size up front. The writer must then send exactly that many bytes. Leave it out if you do not know the size.
- `Results.file` supports resuming and seeking (`Range`): `206` for a valid range, `416` for a range past the end, `HEAD` returns only the headers.
- The bytes are sent as they are, with no text conversion, and a client that disconnects stops the transfer.

Advanced details:

- The header sent is `Content-Disposition: attachment; filename="relazione _.pdf"; filename*=UTF-8''relazione%20%C3%A8.pdf`: a plain ASCII name for old clients plus the exact UTF-8 name (RFC 6266/5987).
- Only a single `bytes=` range is supported. `If-Range` is honoured for a strong `ETag` only, so a weak one gets the full file.
To hand the browser a download from a Vue Live Page, or to make `blob:` downloads work inside a `WKWebView`,
see [Live Pages](../web/LIVE_PAGES_GUIDE.md) and [Blob downloads in WKWebView](../web/BLOB_DOWNLOADS.md).

## Reading a header explicitly

```swift
@Get("/whoami")
func whoami(authorization: Header<String>) async throws -> String {
    "Authorization header was: \(authorization.wrappedValue ?? "none")"
}
```

The Swift parameter's own external label is the header name looked up (matched case-insensitively,
so `authorization` matches `Authorization`) — there's no separate name argument to pass. This only
works for header names that are also legal Swift identifiers (no hyphens); a header like
`X-Request-Id` can't be bound this way — read it from `ctx.request.headers["X-Request-Id"]` inside
a Minimal API closure instead.

## Next

[Advanced examples](EXAMPLES_ADVANCED.md) builds a full CRUD API with `@ApiModel`, DI, rate
limiting, and OpenAPI docs.
