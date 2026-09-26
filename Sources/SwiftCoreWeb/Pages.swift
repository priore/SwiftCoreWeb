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
/// component (the Vue Live Pages design — see `AI-Workspace/Plans/LIVE_PAGES_PLAN.md`).
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
}

extension Page {
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
/// client, or hand back a raw result (an escape hatch, e.g. a file download).
public enum PageAction: Sendable {
    case render
    case redirect(String)
    case result(any HttpResultConvertible)
}

/// Per-request context passed to `onLoad`/`onEvent`, alongside `HttpContext`.
public struct PageContext: Sendable {
    public let http: HttpContext
    public let isPostBack: Bool
    public let args: [String]
    public let errors: PageErrors
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

        return mapMethods([.get, .post], path, auth: auth) { ctx in
            try await self.handlePage(P.self, ctx)
        }
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
        let antiforgery = existingAntiforgery(ctx) ?? {
            let token = makeAntiforgeryToken()
            newAntiforgeryCookie = token
            return token
        }()

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
            result.response.setCookie("__scw_af", newAntiforgeryCookie, secure: tlsOptions != nil, sameSite: "Lax")
        }
        return result
    }

    private func handlePageOrThrow<P: Page>(_ pageType: P.Type, _ ctx: HttpContext, antiforgery: String) async throws -> HttpResult {
        switch ctx.request.method {
        case .get:
            var page = P()
            let pageCtx = PageContext(http: ctx, isPostBack: false, args: [], errors: PageErrors())
            let action = try await page.onLoad(pageCtx)
            if case .redirect(let location) = action {
                return Results.redirect(location)
            }
            if case .result(let result) = action {
                return try result.toHttpResult()
            }
            return try renderShell(page, path: ctx.request.path, antiforgery: antiforgery)

        default: // .post
            guard (ctx.request.headers["Content-Type"] ?? "").hasPrefix("application/json") else {
                throw HttpError(HttpStatusCode(415), "Expected application/json")
            }
            let body = try ctx.request.decode(PageEventRequest.self)
            guard let snapshot = sharedPageSnapshotSignerBox.signer.verify(snapshot: body.snapshot, checksum: body.checksum),
                  snapshot.path == ctx.request.path,
                  snapshot.af == antiforgery else {
                throw HttpError(.badRequest, "Invalid or expired page snapshot")
            }

            var page = try decodePage(P.self, from: snapshot.page)
            let errors = PageErrors()
            bindForm(&page, received: body.form, errors: errors)

            let pageCtx = PageContext(http: ctx, isPostBack: true, args: body.args ?? [], errors: errors)
            let action = try await page.onEvent(body.event, pageCtx)

            switch action {
            case .redirect(let location):
                let (snapshotString, checksum) = try sharedPageSnapshotSignerBox.signer.sign(snapshot)
                return Results.ok(PageEventResponse(snapshot: snapshotString, checksum: checksum, redirect: location))
            case .result(let result):
                return try result.toHttpResult()
            case .render:
                return try renderEventResponse(page, path: ctx.request.path, antiforgery: antiforgery, errors: errors)
            }
        }
    }

    /// Reads `__scw_af` if present, otherwise mints and sets a new one (the
    /// Vue Live Pages design's antiforgery cookie). Returns the value either way.
    private func existingAntiforgery(_ ctx: HttpContext) -> String? {
        ctx.request.cookies["__scw_af"]
    }

    private func makeAntiforgeryToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
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

    private func renderEventResponse<P: Page>(_ page: P, path: String, antiforgery: String, errors: PageErrors) throws -> HttpResult {
        let (snapshotString, checksum) = try sharedPageSnapshotSignerBox.signer.sign(
            try makeSnapshot(page, path: path, antiforgery: antiforgery, errors: errors.snapshot)
        )
        return Results.ok(PageEventResponse(snapshot: snapshotString, checksum: checksum, redirect: nil))
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
