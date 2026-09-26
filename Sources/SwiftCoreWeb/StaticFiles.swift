// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import CryptoKit

/// Resolves a `ContentRoot` to an absolute directory path on disk.
func resolveContentRoot(_ root: ContentRoot) -> String? {
    switch root {
    case .bundle(let name):
        return Bundle.main.url(forResource: name, withExtension: nil)?.path
    case .documents(let name):
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name).path
    case .path(let absolute):
        return absolute
    }
}

/// The MIME type map for `.useStaticFiles`/`.useSpa` (the static file hosting design).
let staticFileMimeTypes: [String: String] = [
    "html": "text/html; charset=utf-8",
    "htm": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "mjs": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "json": "application/json; charset=utf-8",
    "map": "application/json; charset=utf-8",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
    "ico": "image/x-icon",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "wasm": "application/wasm",
    "mp4": "video/mp4",
    "txt": "text/plain; charset=utf-8"
]

/// Resolves `path` (a URL path, e.g. `/assets/app.js`) safely against
/// `root`, blocking traversal and confining symlinks to `root` (the static file hosting design).
///
/// - Returns: The resolved absolute file path, or `nil` if the request does
///   not resolve to a real file inside `root`.
func resolveStaticFilePath(root: String, requestPath: String) -> String? {
    let relative = requestPath.hasPrefix("/") ? String(requestPath.dropFirst()) : requestPath
    guard !relative.contains("..") else { return nil }

    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
    let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL

    // Resolve symlinks and confirm the real path is still confined to root.
    let resolvedRoot = rootURL.resolvingSymlinksInPath().path
    let resolvedCandidate = candidate.resolvingSymlinksInPath().path
    guard resolvedCandidate == resolvedRoot || resolvedCandidate.hasPrefix(resolvedRoot + "/") else {
        return nil
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedCandidate, isDirectory: &isDirectory), !isDirectory.boolValue else {
        return nil
    }
    return resolvedCandidate
}

/// A weak, cheap `ETag` derived from a file's size and modification time —
/// no content hashing, so it stays fast on every request.
func fileETag(path: String) -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int,
          let modified = attrs[.modificationDate] as? Date else {
        return nil
    }
    return "W/\"\(size)-\(Int(modified.timeIntervalSince1970))\""
}

/// Parses a single-range `Range: bytes=start-end` header against a file of
/// `fileSize` bytes. Multi-range requests are not supported (rare for media
/// playback/seek, the actual use case); returns `nil` for anything else,
/// which falls back to a full `200` response.
func parseByteRange(_ header: String, fileSize: Int) -> ClosedRange<Int>? {
    guard fileSize > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
    let spec = header.dropFirst("bytes=".count)
    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    if parts[0].isEmpty {
        // Suffix range: "bytes=-500" → last 500 bytes.
        guard let suffixLength = Int(parts[1]), suffixLength > 0 else { return nil }
        let start = max(fileSize - suffixLength, 0)
        return start...(fileSize - 1)
    }
    guard let start = Int(parts[0]), start < fileSize else { return nil }
    let end = parts[1].isEmpty ? fileSize - 1 : min(Int(parts[1]) ?? fileSize - 1, fileSize - 1)
    guard end >= start else { return nil }
    return start...end
}

/// Whether a hashed, immutable-cacheable asset path (`/assets/*-[hash].*`,
/// per the static file hosting design's cache policy — Vite's default output layout).
private func isHashedAssetPath(_ path: String) -> Bool {
    path.hasPrefix("/assets/") || path.hasPrefix("assets/")
}

/// Picks a precompressed sidecar (`.br` preferred over `.gz`) for `path` if
/// the client's `Accept-Encoding` allows it and the sidecar exists on disk.
func precompressedVariant(for path: String, acceptEncoding: String?) -> (path: String, encoding: String)? {
    guard let acceptEncoding else { return nil }
    if acceptEncoding.contains("br"), FileManager.default.fileExists(atPath: path + ".br") {
        return (path + ".br", "br")
    }
    if acceptEncoding.contains("gzip"), FileManager.default.fileExists(atPath: path + ".gz") {
        return (path + ".gz", "gzip")
    }
    return nil
}

extension WebApplication {
    /// Serves static files from `root` (the static file hosting design): path-traversal blocking,
    /// full MIME map, `ETag`/`If-None-Match` → `304`, `Range` → `206`,
    /// streamed reads, precompressed `.br`/`.gz` sidecars, and the hashed
    /// vs. `index.html` cache policy.
    @discardableResult
    public func useStaticFiles(root: ContentRoot) -> Self {
        return use { ctx, next in
            guard ctx.request.method == .get || ctx.request.method == .head else {
                try await next(); return
            }
            guard let rootPath = resolveContentRoot(root),
                  let filePath = resolveStaticFilePath(root: rootPath, requestPath: ctx.request.path) else {
                try await next(); return
            }
            ctx.response = try staticFileResponse(filePath: filePath, requestPath: ctx.request.path, request: ctx.request)
        }
    }
}

/// Builds the full `HttpResponse` for a resolved static file: MIME type,
/// `ETag`/conditional `304`, `Range`/`206`, precompressed sidecars, and
/// cache headers. Shared by `.useStaticFiles` and the SPA fallback's static
/// file lookup so the two follow identical rules.
func staticFileResponse(filePath: String, requestPath: String, request: HttpRequest) throws -> HttpResponse {
    let ext = (filePath as NSString).pathExtension.lowercased()
    let contentType = staticFileMimeTypes[ext] ?? "application/octet-stream"

    var headers = HttpHeaders()
    headers["Content-Type"] = contentType

    if let etag = fileETag(path: filePath) {
        headers["ETag"] = etag
        if request.headers["If-None-Match"] == etag {
            return HttpResponse(status: .notModified, headers: headers)
        }
    }

    let isIndexHtml = (filePath as NSString).lastPathComponent == "index.html"
    headers["Cache-Control"] = isIndexHtml
        ? "no-cache"
        : (isHashedAssetPath(requestPath) ? "public, max-age=31536000, immutable" : "public, max-age=3600")

    var servedPath = filePath
    if let variant = precompressedVariant(for: filePath, acceptEncoding: request.headers["Accept-Encoding"]) {
        servedPath = variant.path
        headers["Content-Encoding"] = variant.encoding
        headers["Vary"] = "Accept-Encoding"
    }

    guard let attrs = try? FileManager.default.attributesOfItem(atPath: servedPath),
          let fileSize = attrs[.size] as? Int else {
        return Results.notFound().response
    }

    if let rangeHeader = request.headers["Range"],
       let range = parseByteRange(rangeHeader, fileSize: fileSize) {
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"
        headers["Accept-Ranges"] = "bytes"
        return HttpResponse(status: .partialContent, headers: headers, body: .file(path: servedPath, range: range), acceptsRanges: true)
    }

    headers["Accept-Ranges"] = "bytes"
    return HttpResponse(status: .ok, headers: headers, body: .file(path: servedPath, range: nil), acceptsRanges: true)
}
