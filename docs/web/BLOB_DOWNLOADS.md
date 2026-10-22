# Web: blob downloads in WKWebView

[← docs index](../README.md)

You are here if: your web page saves files with `URL.createObjectURL(blob)` and a `<a download>` link, it works in Safari or Chrome, but **nothing happens inside a `WKWebView`** (an iOS/macOS app).

## The short version

Add one line to the server:

```swift
app.useBlobDownloads()
```

Then choose how the download script reaches your page. The easiest: tell the server which client is your app, by naming it in the web view's user agent:

```swift
webView.configuration.applicationNameForUserAgent = "SwiftCoreWebHost/1"
```

The server recognises that name and quietly adds a small script to your HTML pages. That script catches the download and hands the file to the server, which gives it back as a normal download link.

This user agent line is only needed for that automatic way (`injection: .auto`, the default). If you add the script yourself or use `injection: .always`, you can skip it; see [step 2](#2-get-the-script-into-the-page). `BlobDownloadSupport.install(on:)` can set it for you.

Your web code does not change, and desktop browsers are not affected: they never get the script unless you ask for it.

One last piece: the web view itself must accept the download. The easiest way is the optional helper, shown in [step 3](#3-let-the-web-view-save-the-file).

## Why it does not work by default

A `WKWebView` ignores downloads from `blob:` links. It does handle normal downloads: a link to a URL whose response says `Content-Disposition: attachment`. So the trick is to turn the blob into such a URL.

```
page: createObjectURL(blob) + <a download>.click()
        │  (script catches the click)
        ▼
POST /_framework/blob      →  server keeps the bytes for 60 seconds
        ▼
GET /_framework/dl/<token> →  normal attachment download, usable once
```

## Step by step

### 1. Server

```swift
app.useBlobDownloads()
```

It does not need `useVue()`, `usePages()`, sessions or SPA hosting. It also works in a server that only has JSON routes.

Options: `useBlobDownloads(maxBytes: 64 * 1024 * 1024, injection: .auto)`. `maxBytes` is the biggest file accepted (default 64 MB).

### 2. Get the script into the page

Pick one of these (you can use more than one, the script ignores a second load):

| Way | What you do | Good when |
|---|---|---|
| **Automatic** (default) | Set the user agent in the web view: `applicationNameForUserAgent = "SwiftCoreWebHost/1"` (needed only for this way). The server adds the script tag only for that user agent. | The page comes from your SwiftCoreWeb server and you do not want to edit it. |
| **By hand** | Put `<script src="/_framework/blob-download.js"></script>` in your HTML. | You own the HTML and prefer it visible. |
| **From the app** | Add `WKUserScript(source: BlobDownloadShim.source, injectionTime: .atDocumentStart, forMainFrameOnly: false)` to your web view configuration. | The page is not served by this server at all. |

`injection:` controls the automatic way: `.auto` (only for the user agent above), `.always` (everybody) or `.never` (never; the script is still available at `/_framework/blob-download.js`).

### 3. Let the web view save the file

Add the optional `SwiftCoreWebKit` library to your app. It is a small helper object. You keep your own web view and your own navigation delegate, and just forward to the helper:

```swift
import SwiftCoreWebKit

let downloads = BlobDownloadSupport()          // keep a reference to it
downloads.onFinished = { fileURL in
    // show your own save or share screen; the file is yours now
}

let configuration = WKWebViewConfiguration()
BlobDownloadSupport.install(on: configuration) // sets the user agent and adds the script
```

In your own `WKNavigationDelegate`:

```swift
func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    downloads.navigationActionPolicy(for: action)
}
func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
    downloads.navigationResponsePolicy(for: response)
}
func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.adopt(download) }
func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.adopt(download) }
```

The sample app does exactly this: `Showcase/ShowcaseApp/Sources/ShowcaseWebView.swift`.

Without the helper you can write the same two answers yourself: return `.download` for `<a download>` links and for responses with `Content-Disposition: attachment`.

Needs iOS 14.5 / macOS 11.3 or newer (that is when `WKDownload` appeared).

### `window.open` and downloads

`window.open(url)` does nothing in a `WKWebView` unless your `WKUIDelegate` implements `webView(_:createWebViewWith:for:windowFeatures:)`. Load `navigationAction.request` in the same web view and return `nil`. The sample app does this too.

## Check that it works

Try these in your app, on the devices you ship to:

1. A page that creates a blob and clicks a download link saves the file with the right name.
2. A normal link to a file served with `Content-Disposition: attachment` downloads.
3. `window.open` on such a link downloads and the page stays where it is.
4. The same page in Safari or Chrome on the Mac works as before.
5. A file bigger than 10 MB arrives identical.

---

## Advanced: how it works

### The endpoints

| Endpoint | What it does |
|---|---|
| `POST /_framework/blob` | Receives the file bytes as the raw body. Headers: `Content-Type` (the blob type), `X-SCW-Filename` (percent-encoded name) and `X-SCW-Blob: 1` (required, otherwise `403`). Over `maxBytes`: `413`. Answers `{ "url": "/_framework/dl/<token>" }`. It runs through your normal middleware, so your login or host checks apply. |
| `GET /_framework/dl/<token>` | Gives the file back **once**, as an attachment (`filename` and `filename*` for non-ASCII names), with `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`. Unknown, expired, already used or someone else's token: `404`. |
| `GET /_framework/blob-download.js` | The script. The same text is available in Swift as `BlobDownloadShim.source`. |

The required `X-SCW-Blob` header makes browsers send a permission check first when a request comes from another website, so other sites cannot push files into your server.

### Who can fetch a download

The token is 256 random bits, lives about 60 seconds and is tied to the `__scw_af` cookie of the client that uploaded the file (the server creates the cookie if the client has none). If the client also has a session cookie, that must match too. Storage is in memory only, with limits on the number of entries and total bytes; when full, the oldest entries are dropped first.

### The script

It is a normal script from your own origin: it works with `default-src 'self'` and uses no `eval`. It remembers every blob created with `URL.createObjectURL`, and keeps it for about 30 seconds after `revokeObjectURL` (pages usually revoke right after clicking, and the script never reads `blob:` URLs with `fetch`). It reacts to `click()` and to dispatched click events on anchors, even ones not in the page, and to real clicks. Only `<a download href="blob:…">` is touched. If something fails it fires a `blob-download:error` event on `document` and lets the browser try its normal behaviour.

### What the automatic injection changes

The server adds the script tag just before `</head>` of normal `200` HTML responses, whatever produced them (SPA, static files, templates, Live Pages). It does not touch downloads (`attachment`), non-HTML responses, partial (`206`) or `304` responses, or pages that already contain the tag. A changed page loses its `ETag`, gets `Cache-Control: no-cache` and a new `Content-Length`; a precompressed `.br`/`.gz` page is read from its plain version. With `.auto`, changed responses carry `Vary: User-Agent`.
