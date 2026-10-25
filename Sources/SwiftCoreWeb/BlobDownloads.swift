// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// When `useBlobDownloads` adds the shim's `<script>` tag to HTML responses.
public enum BlobShimInjection: Sendable {
    /// Only for clients whose `User-Agent` contains `SwiftCoreWebHost/1`
    /// (set by the host app: `webView.configuration.applicationNameForUserAgent = "SwiftCoreWebHost/1"`).
    case auto
    /// For every client.
    case always
    /// Never; the endpoints and the shim are still served.
    case never
}

/// Live Pages with a `maxUploadBytes` above this spool their `POST`; a blob upload is spooled when it is longer than this.
let spoolThresholdBytes = 8 * 1024 * 1024

private let shimTag = "<script src=\"/_framework/blob-download.js\"></script>"

extension WebApplication {
    /// Enables `blob:` downloads for unmodified web code in web views that
    /// cannot download them natively (WKWebView). Independent of Vue, Pages,
    /// sessions and SPA hosting; works in an API-only app.
    ///
    /// - `POST /_framework/blob`: raw blob bytes (`X-SCW-Blob: 1`, percent-encoded
    ///   `X-SCW-Filename`) → `{ "url": "/_framework/dl/<token>" }`, at most `maxBytes`.
    /// - `GET /_framework/dl/<token>`: serves the bytes once, as an attachment.
    /// - `GET /_framework/blob-download.js`: the client shim (`BlobDownloadShim.source`).
    ///
    /// A blob longer than 8 MB (or of unknown length) is received on disk (`spoolBodyToDisk`) and its
    /// one-time download is served from that file, so a large blob never sits in memory; a smaller one
    /// is handled in memory as before. Disk-backed downloads are bounded by the store's disk budget (`OneTimeDownloadStore.maxDiskBytes`,
    /// `maxDiskEntries`) and the file is deleted once served, expired or evicted. Keep `maxBytes`
    /// modest: the default is 64 MB.
    ///
    /// The one-time URL is bound to the client's antiforgery cookie (minted
    /// here if absent) and, when present, its session cookie.
    @discardableResult
    public func useBlobDownloads(maxBytes: Int = 64 * 1024 * 1024, injection: BlobShimInjection = .auto) -> Self {
        let store = oneTimeDownloads()

        routeRegistry.register(method: .post, path: "/_framework/blob", auth: .none, summary: nil, maxBodySize: maxBytes, spoolAbove: spoolThresholdBytes) { [self] ctx in
            guard ctx.request.headers["X-SCW-Blob"] == "1" else {
                return Results.problem(status: .forbidden, detail: "Missing X-SCW-Blob header")
            }
            let fileName = ctx.request.headers["X-SCW-Filename"].flatMap { $0.removingPercentEncoding } ?? "download"
            let contentType = ctx.request.headers["Content-Type"] ?? "application/octet-stream"

            let response: HttpResponse
            var ownedFile: String?
            if let spooled = ctx.request.bodyFile {
                guard UploadStorage.size(of: spooled) > 0 else { return Results.badRequest("Empty blob") }
                // Moved out of the request's reach: the dispatcher deletes `bodyFile` after the response.
                let kept = try UploadStorage.newFileURL()
                try FileManager.default.moveItem(at: spooled, to: kept)
                ownedFile = kept.path
                response = Results.file(kept.path, contentType: contentType, fileName: fileName).response
            } else {
                guard !ctx.request.body.isEmpty else { return Results.badRequest("Empty blob") }
                response = Results.data(ctx.request.body, contentType: contentType, fileName: fileName).response
            }

            let (af, isNew) = antiforgery(for: ctx.request)
            let owner = DownloadOwner(antiforgery: af, request: ctx.request)
            guard let token = store.put(response, owner: owner, ownedFile: ownedFile) else {
                if let ownedFile { try? FileManager.default.removeItem(atPath: ownedFile) }
                return Results.problem(status: HttpStatusCode(507), detail: "Download store is full")
            }
            var result = Results.ok(["url": "/_framework/dl/\(token)"])
            if isNew { setAntiforgeryCookie(af, on: &result.response) }
            return result
        }

        routeRegistry.register(method: .get, path: "/_framework/blob-download.js", auth: .none, summary: nil) { _ in
            var headers = HttpHeaders()
            headers["Content-Type"] = "text/javascript; charset=utf-8"
            headers["Cache-Control"] = "no-cache"
            return HttpResult(HttpResponse(status: .ok, headers: headers, body: .text(BlobDownloadShim.source)))
        }

        if injection != .never {
            // Prepended: static files and the SPA fallback answer without calling `next()`,
            // so only the outermost step sees every HTML response.
            middlewarePipeline.prepend { ctx, next in
                try await next()
                guard injection == .always || (ctx.request.headers["User-Agent"] ?? "").contains("SwiftCoreWebHost/1") else { return }
                if let injected = injectingShimTag(into: ctx.response, vary: injection == .auto) { ctx.response = injected }
            }
        }
        return self
    }
}

/// `response` with the shim tag added before `</head>`, or `nil` when it is not an
/// injectable document: not a `200` `text/html` (an `attachment` is a file, never a page),
/// no `</head>` (ponytail: such a fragment is left as is), or the tag is already there.
/// The modified document drops its validators (`ETag`, ranges) and caching.
func injectingShimTag(into response: HttpResponse, vary: Bool) -> HttpResponse? {
    guard response.status == .ok,
          (response.headers["Content-Type"] ?? "").lowercased().hasPrefix("text/html"),
          !(response.headers["Content-Disposition"] ?? "").lowercased().hasPrefix("attachment"),
          let html = htmlString(of: response),
          !html.contains("/_framework/blob-download.js"),
          let head = html.range(of: "</head>", options: .caseInsensitive) else { return nil }

    var result = response
    result.body = .text(html.replacingCharacters(in: head.lowerBound..<head.lowerBound, with: shimTag))
    result.acceptsRanges = false
    for name in ["ETag", "Accept-Ranges", "Content-Length", "Content-Encoding"] { result.headers[name] = nil }
    result.headers["Cache-Control"] = "no-cache"
    if vary { result.headers["Vary"] = [response.headers["Vary"], "User-Agent"].compactMap { $0 }.joined(separator: ", ") }
    return result
}

/// The uncompressed HTML of `response`. A precompressed static file is read from
/// its plain sibling (`index.html.gz` → `index.html`); other body kinds are skipped.
private func htmlString(of response: HttpResponse) -> String? {
    switch response.body {
    case .text(let string):
        return string
    case .data(let data):
        return String(data: data, encoding: .utf8)
    case .file(var path, nil):
        if response.headers["Content-Encoding"] != nil {
            guard let suffix = [".br", ".gz"].first(where: path.hasSuffix) else { return nil }
            path.removeLast(suffix.count)
        }
        // ponytail: HTML documents are small; bigger than 8 MB is not a page, left untouched.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= 8_000_000 else { return nil }
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { String(data: $0, encoding: .utf8) }
    default:
        return nil
    }
}
