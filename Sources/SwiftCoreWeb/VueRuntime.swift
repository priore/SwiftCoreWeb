// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// The built-in Vue 3 runtime shipped as an SPM resource (the built-in Vue runtime design), MIT
/// licensed (see `LICENSE-THIRD-PARTY`). Works offline on the device with no
/// CDN, npm, or Node — `app.useVue()` serves it at `/_framework/vue.js`.
public enum VueRuntime {
    /// The pinned Vue build version, kept in sync with the vendored file by
    /// `scripts/update-vue.sh`.
    public static let version = "3.4.38"
}

/// A tiny `fetch` wrapper served at `/_framework/api.js` (the built-in Vue runtime design): returns
/// parsed JSON and throws on a ProblemDetails response, so a junior calls
/// `await api.get('/api/users')` instead of hand-rolling `fetch` + error
/// handling on every call site.
private let apiHelperScript = """
export async function request(method, path, body) {
  const init = { method, headers: {} };
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const response = await fetch(path, init);
  const contentType = response.headers.get('Content-Type') || '';
  const payload = contentType.includes('application/json') ? await response.json() : await response.text();
  if (!response.ok) {
    const error = new Error((payload && payload.detail) || (payload && payload.title) || response.statusText);
    error.status = response.status;
    error.problem = payload;
    throw error;
  }
  return payload;
}

export const api = {
  get: (path) => request('GET', path),
  post: (path, body) => request('POST', path, body),
  put: (path, body) => request('PUT', path, body),
  patch: (path, body) => request('PATCH', path, body),
  delete: (path) => request('DELETE', path)
};
"""

extension WebApplication {
    /// Serves the built-in Vue 3 runtime at `/_framework/vue.js` with
    /// immutable caching, plus the optional `/_framework/api.js` `fetch`
    /// helper (the built-in Vue runtime design). Precompressed `.gz`/`.br` sidecars are served
    /// automatically when present alongside the bundled resource and the
    /// client's `Accept-Encoding` allows it.
    @discardableResult
    public func useVue() -> Self {
        routeRegistry.register(method: .get, path: "/_framework/vue.js", auth: .none, summary: nil) { ctx in
            guard let url = Bundle.module.url(forResource: "vue.esm-browser.prod", withExtension: "js", subdirectory: "vue") else {
                return Results.notFound()
            }
            return try Self.immutableFrameworkAsset(at: url.path, contentType: "text/javascript; charset=utf-8", request: ctx.request)
        }

        routeRegistry.register(method: .get, path: "/_framework/api.js", auth: .none, summary: nil) { _ in
            var headers = HttpHeaders()
            headers["Content-Type"] = "text/javascript; charset=utf-8"
            headers["Cache-Control"] = "public, max-age=31536000, immutable"
            return HttpResult(HttpResponse(status: .ok, headers: headers, body: .text(apiHelperScript)))
        }

        return self
    }

    private static func immutableFrameworkAsset(at path: String, contentType: String, request: HttpRequest) throws -> HttpResult {
        var headers = HttpHeaders()
        headers["Content-Type"] = contentType
        headers["Cache-Control"] = "public, max-age=31536000, immutable"

        var servedPath = path
        if let variant = precompressedVariant(for: path, acceptEncoding: request.headers["Accept-Encoding"]) {
            servedPath = variant.path
            headers["Content-Encoding"] = variant.encoding
            headers["Vary"] = "Accept-Encoding"
        }
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .file(path: servedPath, range: nil)))
    }
}
