// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import CryptoKit
import Security
import NIOConcurrencyHelpers

/// A server-rendered, stateful page whose template is a precompiled Vue
/// component (the Vue Live Pages design).
///
/// `form` is the only part of the page a client may modify; every other
/// stored property is server state the client can see (in the signed
/// snapshot) but cannot tamper with. `Sendable`: `P()`/`P.template` are read
/// from a `@Sendable` route closure (`RouteRegistry.swift:27`).
public protocol Page: Codable, Sendable {
    associatedtype Form: Codable & Sendable = NoForm
    static var template: String { get }
    static var title: String { get }
    static var stylesheets: [String] { get }
    var form: Form { get set }
    init()
    mutating func onLoad(_ ctx: PageContext) async throws -> PageAction?
    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction
    /// Upper bound for the total size of files uploaded in one event
    /// (`$swiftUpload`); also lifts the request body limit of this page's `POST`
    /// route to that size. `nil` = the app's global request body limit. Over: `413`.
    static var maxUploadBytes: Int? { get }
    /// Allowed upload types: MIME types (`image/png`), wildcards (`image/*`) or
    /// extensions (`.pdf`). `nil` = any. A violation sets `ctx.errors["files"]`
    /// and `ctx.files` stays empty.
    static var allowedUploadTypes: [String]? { get }
    /// Maximum number of files per event; a violation is handled like a type violation.
    static var maxUploadFiles: Int? { get }
}

extension Page {
    public static var maxUploadBytes: Int? { nil }
    public static var allowedUploadTypes: [String]? { nil }
    public static var maxUploadFiles: Int? { nil }
    public static var title: String { "" }
    public static var stylesheets: [String] { [] }
    public mutating func onLoad(_ ctx: PageContext) async throws -> PageAction? { nil }
    public mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction { .render }
}

extension Page where Form == NoForm {
    public var form: NoForm {
        get { NoForm() }
        set {}
    }
}

/// The outcome of `onLoad`/`onEvent`: re-render the page, redirect the
/// client, hand the client a download, or hand back a raw result (an escape hatch).
///
/// From `onEvent`, a `.result` is not sent to the browser as-is: the Live Pages
/// client expects JSON, so a redirect result becomes a client redirect, an empty
/// `2xx` re-renders, and any other `2xx` body is stored as a one-time download
/// (like `download(...)`). Other statuses are passed through and surface as a
/// `live:error` event on the client.
public enum PageAction: Sendable {
    case render
    case redirect(String)
    case result(any HttpResultConvertible)
}

/// A download built by `PageAction.download(...)`: a complete attachment response.
/// Returned from `onLoad` (a `GET`) it is served directly.
struct PageDownload: HttpResultConvertible {
    let response: HttpResponse
    func toHttpResult() throws -> HttpResult { HttpResult(response) }
}

extension PageAction {
    /// Sends `data` to the browser as a file download, without a `blob:` URL: the
    /// event replies with a one-time `/_framework/dl/<token>` URL the client navigates to.
    public static func download(data: Data, fileName: String, contentType: String = "application/octet-stream") -> PageAction {
        .result(PageDownload(response: Results.data(data, contentType: contentType, fileName: fileName).response))
    }

    /// Sends the file at `filePath` (read when the browser fetches it, not now).
    public static func download(filePath: String, fileName: String? = nil, contentType: String = "application/octet-stream") -> PageAction {
        .result(PageDownload(response: Results.file(filePath, contentType: contentType, fileName: fileName ?? (filePath as NSString).lastPathComponent).response))
    }

    /// Sends bytes produced by `stream` when the browser fetches the download.
    public static func download(
        fileName: String,
        contentType: String = "application/octet-stream",
        stream: @escaping @Sendable (any AsyncByteSink) async throws -> Void
    ) -> PageAction {
        .result(PageDownload(response: Results.stream(contentType: contentType, fileName: fileName, stream).response))
    }
}

/// Per-request context passed to `onLoad`/`onEvent`, alongside `HttpContext`.
public struct PageContext: Sendable {
    public let http: HttpContext
    public let isPostBack: Bool
    public let args: [String]
    public let errors: PageErrors
    /// Files uploaded with this event (`$swiftUpload`); temporary files are deleted
    /// after the response unless moved with `UploadedFile.move(to:)`.
    public let files: [UploadedFile]
    public var isValid: Bool { errors.isEmpty }
    public var session: Session { http.session }
}

/// Field-level validation errors set by `onLoad`/`onEvent`
/// (`ctx.errors["name"] = "Required"`), rendered into the page as `errors.name`.
/// A class (not a struct) so `PageContext` can hand it out by reference while
/// `onEvent` mutates it — mirrors ASP.NET's `ModelState`.
public final class PageErrors: @unchecked Sendable {
    private let lock = NIOLock()
    private var storage: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return storage.isEmpty }

    public subscript(field: String) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return storage[field] }
        set { lock.lock(); defer { lock.unlock() }; storage[field] = newValue }
    }

    var snapshot: [String: String] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// A choice for a `select`/radio/checkbox-group binding.
public struct Choice: Codable, Sendable {
    public let value: String
    public let label: String
    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// The default `Form` for a `Page` that has no user-editable fields.
public struct NoForm: Codable, Sendable {
    public init() {}
}

// MARK: - Snapshot

/// The signed, opaque state the client round-trips on every event
/// (the Vue Live Pages design's snapshot protocol). `page` is the page's own
/// `Codable` encoding merged with the current `errors`; the client never
/// decodes `page` itself, it renders it via Vue.
struct PageSnapshot: Codable, Sendable {
    let path: String
    let af: String
    let page: JSONValue
}

/// A minimal untyped JSON value, just enough to merge a `Page`'s encoded
/// fields with `errors` into one object without a concrete `Decodable` type
/// on the other end (the client only ever `JSON.parse`s this).
enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Merges `fields` into this value if it is an `.object`, overwriting any
    /// existing keys of the same name (used to add `errors` to the encoded page).
    func merging(_ fields: [String: JSONValue]) -> JSONValue {
        guard case .object(var dict) = self else { return self }
        for (key, value) in fields { dict[key] = value }
        return .object(dict)
    }
}

/// HMAC-SHA256 signing for page snapshots, keyed by a per-process
/// `SymmetricKey` (the Vue Live Pages design).
/// `// ponytail: per-process key, pages reload after server restart; persist in Keychain if needed`.
final class PageSnapshotSigner: @unchecked Sendable {
    private let key = SymmetricKey(size: .bits256)

    /// Encodes `snapshot` to JSON and returns `(snapshotString, hexChecksum)`.
    func sign(_ snapshot: PageSnapshot) throws -> (snapshot: String, checksum: String) {
        let data = try JSONEncoder().encode(snapshot)
        guard let string = String(data: data, encoding: .utf8) else {
            throw HttpError(.internalServerError, "Failed to encode page snapshot")
        }
        let code = HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: key)
        return (string, Data(code).map { String(format: "%02x", $0) }.joined())
    }

    /// Verifies `checksum` against `snapshot` in constant time, then decodes it.
    func verify(snapshot: String, checksum: String) -> PageSnapshot? {
        guard let checksumBytes = Data(hexString: checksum) else { return nil }
        guard HMAC<SHA256>.isValidAuthenticationCode(checksumBytes, authenticating: Data(snapshot.utf8), using: key) else {
            return nil
        }
        return try? JSONDecoder().decode(PageSnapshot.self, from: Data(snapshot.utf8))
    }
}

private extension Data {
    /// Decodes a lowercase/uppercase hex string into bytes, or `nil` if malformed.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

/// Holds the `WebApplication`-scoped `PageSnapshotSigner`, mirroring
/// `TemplateCacheBox`/`VueTemplateCompilerBox` (one `WebApplication` per
/// process is the supported shape).
final class PageSnapshotSignerBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var _signer: PageSnapshotSigner?
    var signer: PageSnapshotSigner {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _signer { return existing }
        let created = PageSnapshotSigner()
        _signer = created
        return created
    }
}

let sharedPageSnapshotSignerBox = PageSnapshotSignerBox()

// MARK: - Wire payloads

/// The POST event request body: `{ snapshot, checksum, form, event, args }`.
private struct PageEventRequest: Decodable {
    let snapshot: String
    let checksum: String
    let form: JSONValue?
    let event: String
    let args: [String]?
}

/// The response to both GET (embedded in `#__live`) and POST: the new
/// signed snapshot, plus `redirect` when the page navigated away.
private struct PageEventResponse: Encodable {
    let snapshot: String
    let checksum: String
    let redirect: String?
    /// `/_framework/dl/<token>` when the event produced a download.
    var download: String? = nil
}

// MARK: - mapPage

extension WebApplication {
    /// Registers a template root pages are compiled/served from
    /// (`GET /_live/<page>.js`). The root is **not** served as static files.
    @discardableResult
    public func usePages(root: ContentRoot = .bundle("Views")) -> Self {
        sharedPagesRootBox.setRoot(root, for: self)
        return self
    }

    /// Registers a `Page` at `path`: `GET` renders the shell (running
    /// `onLoad`), `POST` handles a client event (running `onEvent`). Also
    /// registers `GET /_live/<page's template>.js` once per `WebApplication`,
    /// serving the precompiled Vue render function for that page's template.
    @discardableResult
    public func mapPage<P: Page>(_ path: String, _ pageType: P.Type, auth: AuthRequirement = .none) -> Self {
        let liveScriptPath = "/_live/\(P.template.replacingOccurrences(of: ".html", with: "")).js"
        if sharedLiveScriptRegistry.insert(liveScriptPath, for: self) {
            routeRegistry.register(method: .get, path: liveScriptPath, auth: .none, summary: nil) { ctx in
                try self.liveScriptResult(for: P.template)
            }
        }

        oneTimeDownloads() // `.download` events fetch from /_framework/dl/{token}, which must exist before the router freezes

        // Room for the snapshot/form fields next to the files.
        let postLimit = P.maxUploadBytes.map { $0 + 1_048_576 }
        // Big uploads are received on disk. The snapshot, checksum and `X-SCW-Live` checks still run
        // in `handlePage`, after the body is complete; the parts are discarded if they fail.
        let spool = (P.maxUploadBytes ?? 0) > spoolThresholdBytes
        for method in [HttpMethod.get, .post] {
            routeRegistry.register(method: method, path: path, auth: auth, summary: nil, maxBodySize: method == .post ? postLimit : nil, spoolBody: method == .post && spool) { ctx in
                try await self.handlePage(P.self, ctx)
            }
        }
        return self
    }

    private func liveScriptResult(for templateName: String) throws -> HttpResult {
        guard let rootPath = resolveContentRoot(sharedPagesRootBox.root(for: self)),
              let filePath = resolveStaticFilePath(root: rootPath, requestPath: "/" + templateName) else {
            throw HttpError(.notFound, "Page template '\(templateName)' not found")
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date) ?? nil
        guard let source = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            throw HttpError(.notFound, "Page template '\(templateName)' not found")
        }
        let compiler = sharedPagesCompilerBox.compiler(for: self, isDevelopment: environment == .development)
        let compiled = try compiler.compile(name: templateName, template: source, modified: modified ?? .distantPast)

        var headers = HttpHeaders()
        headers["Content-Type"] = "text/javascript; charset=utf-8"
        headers["Cache-Control"] = environment == .development ? "no-cache" : "public, max-age=31536000, immutable"
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .text(compiled)))
    }

    private func handlePage<P: Page>(_ pageType: P.Type, _ ctx: HttpContext) async throws -> HttpResult {
        // The route handler's return value replaces `ctx.response` wholesale
        // (`RequestDispatcher.swift`'s `boundCtx.response = ...`), so a cookie
        // must be added to the `HttpResult` actually returned, not to
        // `ctx.response` directly — that mutation would just be discarded.
        var newAntiforgeryCookie: String?
        let (antiforgery, isNew) = self.antiforgery(for: ctx.request)
        if isNew { newAntiforgeryCookie = antiforgery }

        var result: HttpResult
        do {
            result = try await handlePageOrThrow(P.self, ctx, antiforgery: antiforgery)
        } catch let httpError as HttpError {
            // Converted here rather than relying on `.useExceptionHandler()`:
            // the protocol/event errors below (invalid snapshot, wrong
            // Content-Type) are this feature's own defined 400/415 responses,
            // not generic unhandled-error 500s.
            result = Results.problem(status: httpError.status, detail: httpError.detail)
        }
        if let newAntiforgeryCookie {
            setAntiforgeryCookie(newAntiforgeryCookie, on: &result.response)
        }
        return result
    }

    private func handlePageOrThrow<P: Page>(_ pageType: P.Type, _ ctx: HttpContext, antiforgery: String) async throws -> HttpResult {
        switch ctx.request.method {
        case .get:
            var page = P()
            let pageCtx = PageContext(http: ctx, isPostBack: false, args: [], errors: PageErrors(), files: [])
            let action = try await page.onLoad(pageCtx)
            if case .redirect(let location) = action {
                return Results.redirect(location)
            }
            if case .result(let result) = action {
                return try result.toHttpResult()
            }
            return try renderShell(page, path: ctx.request.path, antiforgery: antiforgery)

        default: // .post
            let (body, uploads) = try eventRequest(ctx)
            guard let snapshot = sharedPageSnapshotSignerBox.signer.verify(snapshot: body.snapshot, checksum: body.checksum),
                  snapshot.path == ctx.request.path,
                  snapshot.af == antiforgery else {
                throw HttpError(.badRequest, "Invalid or expired page snapshot")
            }

            var page = try decodePage(P.self, from: snapshot.page)
            let errors = PageErrors()
            bindForm(&page, received: body.form, errors: errors)
            let files = try acceptUploads(P.self, uploads, errors: errors)

            let pageCtx = PageContext(http: ctx, isPostBack: true, args: body.args ?? [], errors: errors, files: files)
            let action = try await page.onEvent(body.event, pageCtx)

            switch action {
            case .redirect(let location):
                let (snapshotString, checksum) = try sharedPageSnapshotSignerBox.signer.sign(snapshot)
                return Results.ok(PageEventResponse(snapshot: snapshotString, checksum: checksum, redirect: location))
            case .result(let result):
                return try eventResult(result, page: page, ctx: ctx, antiforgery: antiforgery, errors: errors)
            case .render:
                return try renderEventResponse(page, path: ctx.request.path, antiforgery: antiforgery, errors: errors)
            }
        }
    }

    /// The event request, from `application/json` or, for uploads, `multipart/form-data`
    /// with the fields `snapshot`, `checksum`, `event`, `args` (JSON), `form` (JSON) plus file parts.
    /// A multipart request must carry `X-SCW-Live: 1`: a custom header cannot be sent
    /// cross-site without a CORS preflight, which a plain `<form>` post (no preflight) could skip.
    private func eventRequest(_ ctx: HttpContext) throws -> (PageEventRequest, [UploadedFile]) {
        let contentType = (ctx.request.headers["Content-Type"] ?? "").lowercased()
        if contentType.hasPrefix("multipart/form-data") {
            guard ctx.request.headers["X-SCW-Live"] == "1" else {
                throw HttpError(.forbidden, "Missing X-SCW-Live header")
            }
            // ponytail: the parts are written to temporary files before the snapshot is verified
            // (bounded by the route's body limit, deleted after the response).
            let form = try SwiftCoreWeb.bindForm(ctx)
            guard let snapshot = form.fields["snapshot"], let checksum = form.fields["checksum"], let event = form.fields["event"] else {
                throw HttpError(.badRequest, "Missing snapshot, checksum or event")
            }
            func json<T: Decodable>(_ key: String, as type: T.Type) -> T? {
                form.fields[key].flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
            }
            let request = PageEventRequest(snapshot: snapshot, checksum: checksum, form: json("form", as: JSONValue.self), event: event, args: json("args", as: [String].self))
            return (request, form.files)
        }
        guard contentType.hasPrefix("application/json") else {
            throw HttpError(HttpStatusCode(415), "Expected application/json")
        }
        // A spooled route also receives its JSON events on disk; they are small.
        let data = try ctx.request.smallBody()
        do {
            return (try JSONDecoder().decode(PageEventRequest.self, from: data), [])
        } catch {
            throw HttpError(.badRequest, "Could not decode request body as PageEventRequest: \(error)")
        }
    }

    /// Applies the page's upload limits: over `maxUploadBytes` is a `413`; too many files
    /// or a disallowed type sets `errors["files"]` and drops the files.
    private func acceptUploads<P: Page>(_ type: P.Type, _ files: [UploadedFile], errors: PageErrors) throws -> [UploadedFile] {
        if let maxBytes = P.maxUploadBytes, files.reduce(0, { $0 + $1.sizeInBytes }) > maxBytes {
            throw HttpError(.payloadTooLarge, "Upload exceeds \(maxBytes) bytes")
        }
        if let maxFiles = P.maxUploadFiles, files.count > maxFiles {
            errors["files"] = "At most \(maxFiles) file(s) allowed"
            return []
        }
        if let allowed = P.allowedUploadTypes, !files.allSatisfy({ file in allowed.contains { uploadMatches(file, $0) } }) {
            errors["files"] = "File type not allowed"
            return []
        }
        return files
    }

    private func uploadMatches(_ file: UploadedFile, _ pattern: String) -> Bool {
        let pattern = pattern.lowercased()
        if pattern.hasPrefix(".") { return file.fileName.lowercased().hasSuffix(pattern) }
        let type = (file.contentType ?? "").lowercased()
        return pattern.hasSuffix("/*") ? type.hasPrefix(pattern.dropLast()) : type == pattern
    }

    /// `PageAction.result` from an event. The client only understands page JSON, so:
    /// a redirect result redirects, an empty `2xx` re-renders, another `2xx` body becomes
    /// a one-time download, anything else is returned unchanged (the client reports `live:error`).
    private func eventResult<P: Page>(_ result: any HttpResultConvertible, page: P, ctx: HttpContext, antiforgery: String, errors: PageErrors) throws -> HttpResult {
        let http = try result.toHttpResult()
        let response = http.response
        if (300..<400).contains(response.status.rawValue), let location = response.headers["Location"] {
            return try renderEventResponse(page, path: ctx.request.path, antiforgery: antiforgery, errors: errors, redirect: location)
        }
        guard (200..<300).contains(response.status.rawValue) else { return http }
        if case .empty = response.body {
            return try renderEventResponse(page, path: ctx.request.path, antiforgery: antiforgery, errors: errors)
        }
        let owner = DownloadOwner(antiforgery: antiforgery, request: ctx.request)
        guard let token = oneTimeDownloads().put(response, owner: owner) else {
            throw HttpError(HttpStatusCode(507), "Download too large")
        }
        return try renderEventResponse(page, path: ctx.request.path, antiforgery: antiforgery, errors: errors, download: "/_framework/dl/\(token)")
    }

    private func renderShell<P: Page>(_ page: P, path: String, antiforgery: String) throws -> HttpResult {
        let (snapshotString, checksum) = try sharedPageSnapshotSignerBox.signer.sign(
            try makeSnapshot(page, path: path, antiforgery: antiforgery, errors: [:])
        )
        let payload = try JSONEncoder().encode(PageEventResponse(snapshot: snapshotString, checksum: checksum, redirect: nil))
        guard let payloadJSON = String(data: payload, encoding: .utf8) else {
            throw HttpError(.internalServerError, "Failed to encode page payload")
        }
        let templateSlug = P.template.replacingOccurrences(of: ".html", with: "")
        let stylesheets = P.stylesheets.map { "<link rel=\"stylesheet\" href=\"\($0)\">" }.joined()

        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(TemplateEngine.escapeForInlineScript(P.title))</title>\(stylesheets)</head>
        <body><div id="app"></div>
        <script type="application/json" id="__live">\(TemplateEngine.escapeForInlineScript(payloadJSON))</script>
        <script src="/_live/\(templateSlug).js"></script>
        <script type="module" src="/_framework/live.js"></script></body></html>
        """

        var headers = HttpHeaders()
        headers["Content-Type"] = "text/html; charset=utf-8"
        return HttpResult(HttpResponse(status: .ok, headers: headers, body: .text(html)))
    }

    private func renderEventResponse<P: Page>(_ page: P, path: String, antiforgery: String, errors: PageErrors, redirect: String? = nil, download: String? = nil) throws -> HttpResult {
        let (snapshotString, checksum) = try sharedPageSnapshotSignerBox.signer.sign(
            try makeSnapshot(page, path: path, antiforgery: antiforgery, errors: errors.snapshot)
        )
        return Results.ok(PageEventResponse(snapshot: snapshotString, checksum: checksum, redirect: redirect, download: download))
    }

    private func makeSnapshot<P: Page>(_ page: P, path: String, antiforgery: String, errors: [String: String]) throws -> PageSnapshot {
        let data = try JSONEncoder().encode(page)
        let pageJSON = try JSONDecoder().decode(JSONValue.self, from: data)
        let errorsJSON = JSONValue.object(errors.mapValues { .string($0) })
        return PageSnapshot(path: path, af: antiforgery, page: pageJSON.merging(["errors": errorsJSON]))
    }

    private func decodePage<P: Page>(_ type: P.Type, from json: JSONValue) throws -> P {
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(P.self, from: data)
    }

    /// Overlays `received` (the client's `form` object) onto the page's
    /// current `form`, decoding key-by-key on failure so one bad field
    /// (`qty: "abc"`) doesn't lose every other field — it lands in `errors`
    /// instead, mirroring ASP.NET's `ModelState` (never a 400 for user input).
    private func bindForm<P: Page>(_ page: inout P, received: JSONValue?, errors: PageErrors) {
        guard let received, case .object(let receivedFields) = received else { return }

        let currentData = (try? JSONEncoder().encode(page.form)) ?? Data()
        guard var currentFields = (try? JSONDecoder().decode(JSONValue.self, from: currentData)),
              case .object(var fieldDict) = currentFields else { return }

        for (key, value) in receivedFields {
            fieldDict[key] = value
        }
        currentFields = .object(fieldDict)

        guard let mergedData = try? JSONEncoder().encode(currentFields) else { return }
        if let decoded = try? JSONDecoder().decode(P.Form.self, from: mergedData) {
            page.form = decoded
            return
        }

        // Whole-form decode failed: retry field-by-field, keeping the
        // previous value for any field that doesn't convert.
        for (key, value) in receivedFields {
            var attemptFields = fieldDict
            attemptFields[key] = value
            guard let attemptData = try? JSONEncoder().encode(JSONValue.object(attemptFields)),
                  (try? JSONDecoder().decode(P.Form.self, from: attemptData)) != nil else {
                errors[key] = "Invalid value"
                continue
            }
        }
    }
}

/// Holds the pages template root per `WebApplication` (keyed by identity,
/// like `TemplateCacheBox` holds one per app but without a stored property on
/// `WebApplication` itself — `mapPage`/`usePages` live in this file only).
final class PagesRootBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var roots: [ObjectIdentifier: ContentRoot] = [:]
    func setRoot(_ root: ContentRoot, for app: WebApplication) {
        lock.lock(); defer { lock.unlock() }
        roots[ObjectIdentifier(app)] = root
    }
    func root(for app: WebApplication) -> ContentRoot {
        lock.lock(); defer { lock.unlock() }
        return roots[ObjectIdentifier(app)] ?? .bundle("Views")
    }
}
let sharedPagesRootBox = PagesRootBox()

/// Tracks which pages' `/_live/<name>.js` routes are already registered per
/// `WebApplication`, so two `Page`s sharing a template don't double-register
/// the route on the same app's router (two different apps must each register
/// their own route, since each has its own `routeRegistry`).
final class LiveScriptRegistry: @unchecked Sendable {
    private let lock = NIOLock()
    private var registered: [ObjectIdentifier: Set<String>] = [:]
    /// Returns `true` if `path` was newly inserted for `app` (i.e. this call should register the route).
    func insert(_ path: String, for app: WebApplication) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registered[ObjectIdentifier(app), default: []].insert(path).inserted
    }
}
let sharedLiveScriptRegistry = LiveScriptRegistry()

/// Holds one `VueTemplateCompiler` per `WebApplication` (keyed by identity) —
/// each app's compiled-template cache must not leak into another app's, which
/// bites as soon as more than one `WebApplication` exists in the same process
/// (every test in `PagesTests` does).
final class PagesCompilerBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var compilers: [ObjectIdentifier: VueTemplateCompiler] = [:]
    func compiler(for app: WebApplication, isDevelopment: Bool) -> VueTemplateCompiler {
        lock.lock(); defer { lock.unlock() }
        if let existing = compilers[ObjectIdentifier(app)] { return existing }
        let created = VueTemplateCompiler(isDevelopment: isDevelopment)
        compilers[ObjectIdentifier(app)] = created
        return created
    }
}
let sharedPagesCompilerBox = PagesCompilerBox()
