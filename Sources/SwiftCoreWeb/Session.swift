// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import Security
import NIOConcurrencyHelpers

/// A per-visitor server-side key/value store, backed by an `__scw_sid` cookie
/// (the Vue Live Pages design's session support). Typed access via `Codable`.
///
/// Created lazily: reading `ctx.session` never mints a cookie by itself, only
/// the first `set(...)` does (anti session-fixation stays meaningful — an
/// unrecognized incoming id is never adopted either way).
/// `// ponytail: in-memory, single process — not shared across server restarts or instances`.
public final class Session: @unchecked Sendable {
    private let lock = NIOLock()
    private var storage: [String: Data] = [:]

    /// Non-nil once this session has a server-minted id (either it already
    /// existed, or the first `set` created one) — set by `HttpContext.session`.
    fileprivate var onFirstWrite: (() -> Void)?

    init() {}

    /// Reads a value previously `set`, decoded as `T`, or `nil` if absent or undecodable.
    public func get<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Stores `value` under `key`, encoded as JSON. Creates the session's
    /// server-side entry (and queues its `Set-Cookie`) on the first call.
    public func set<T: Encodable>(_ value: T, _ key: String) {
        lock.lock()
        let firstWrite = onFirstWrite
        onFirstWrite = nil
        guard let data = try? JSONEncoder().encode(value) else { lock.unlock(); return }
        storage[key] = data
        lock.unlock()
        firstWrite?()
    }

    /// Removes the value stored under `key`, if any.
    public func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

/// In-memory session store, keyed by the `__scw_sid` cookie value. Sweeps
/// expired/excess entries lazily on `create()` rather than a background timer.
final class SessionStore: @unchecked Sendable {
    private struct Entry { let session: Session; var lastAccessed: Date }

    private let lock = NIOLock()
    private var entries: [String: Entry] = [:]
    let idleTimeout: TimeInterval
    let maxEntries: Int

    init(idleTimeout: TimeInterval, maxEntries: Int) {
        self.idleTimeout = idleTimeout
        self.maxEntries = maxEntries
    }

    /// Returns the existing, non-expired session for `id`, or `nil` — never
    /// creates one (a bare read must not adopt an unrecognized/expired id).
    func existing(id: String?) -> Session? {
        guard let id else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id], Date().timeIntervalSince(entry.lastAccessed) < idleTimeout else {
            entries.removeValue(forKey: id)
            return nil
        }
        entry.lastAccessed = Date()
        entries[id] = entry
        return entry.session
    }

    /// Registers `session` under a fresh, server-minted id and returns it.
    func register(_ session: Session) -> String {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.lastAccessed) < idleTimeout }
        if entries.count >= maxEntries, let oldest = entries.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key {
            entries.removeValue(forKey: oldest)
        }
        var bytes = [UInt8](repeating: 0, count: 16) // 128 bits
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = Data(bytes).base64EncodedString()
        entries[id] = Entry(session: session, lastAccessed: now)
        return id
    }
}

/// Holds the `WebApplication`-scoped `SessionStore`, mirroring `TemplateCacheBox`.
final class SessionStoreBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var _store: SessionStore?
    var store: SessionStore? {
        get { lock.lock(); defer { lock.unlock() }; return _store }
        set { lock.lock(); defer { lock.unlock() }; _store = newValue }
    }
}
let sharedSessionStoreBox = SessionStoreBox()

/// The `__scw_sid` value to `Set-Cookie` after the handler runs, queued by
/// `HttpContext.session` into `ctx.items` so `.useSession()`'s middleware can
/// flush it post-`next()` (the `.useSecurityHeaders()` pattern) — a fresh
/// session's cookie can't be known before the handler decides to create one.
struct SessionCookieToSet: Sendable {
    let id: String
}

extension HttpContext {
    /// The session for this request. Reading it alone (no `.set(...)`) never
    /// creates a server-side entry or `Set-Cookie`; an unrecognized/expired
    /// incoming `__scw_sid` is never adopted, only ever replaced.
    ///
    /// - Precondition: `.useSession()` must be registered on the app.
    public var session: Session {
        if let cached = items[Session.self] { return cached }
        guard let store = sharedSessionStoreBox.store else {
            preconditionFailure("SwiftCoreWeb: session accessed without app.useSession(). Call app.useSession() before using ctx.session.")
        }
        let session: Session
        if let existing = store.existing(id: request.cookies["__scw_sid"]) {
            session = existing
        } else {
            session = Session()
            session.onFirstWrite = { [weak self] in
                let id = store.register(session)
                self?.items[SessionCookieToSet.self] = SessionCookieToSet(id: id)
            }
        }
        items[Session.self] = session
        return session
    }
}

extension WebApplication {
    /// Enables `ctx.session`, backed by an in-memory store keyed by the
    /// `__scw_sid` cookie (the Vue Live Pages design). `idleTimeout` in seconds
    /// (`TimeInterval`, not `Duration` — iOS 15/macOS 11 minimum).
    @discardableResult
    public func useSession(idleTimeout: TimeInterval = 1200, maxEntries: Int = 10_000) -> Self {
        sharedSessionStoreBox.store = SessionStore(idleTimeout: idleTimeout, maxEntries: maxEntries)
        return use { ctx, next in
            try await next()
            if let toSet = ctx.items[SessionCookieToSet.self] {
                ctx.response.setCookie("__scw_sid", toSet.id, sameSite: "Lax")
            }
        }
    }
}
