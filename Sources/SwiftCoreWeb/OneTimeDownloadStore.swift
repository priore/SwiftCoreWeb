// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import Security
import NIOConcurrencyHelpers

/// Who may fetch a one-time download: the antiforgery cookie of the request
/// that created it and, when that request had one, its session cookie.
struct DownloadOwner: Sendable, Equatable {
    let antiforgery: String
    let session: String?

    init(antiforgery: String, request: HttpRequest) {
        self.antiforgery = antiforgery
        self.session = request.cookies["__scw_sid"]
    }

    func matches(_ request: HttpRequest) -> Bool {
        guard Antiforgery.existing(request) == antiforgery else { return false }
        return session == nil || request.cookies["__scw_sid"] == session
    }
}

/// Short-lived, bounded, in-memory holder of responses served exactly once at
/// `GET /_framework/dl/<token>`. Shared by Live Pages downloads and blob
/// downloads; nothing is persisted. Expired entries are evicted on every call.
///
/// ponytail: only in-memory bodies count against `maxTotalBytes`; `.file` and
/// `.stream` entries cost no RAM until served. When full the oldest entries are dropped.
final class OneTimeDownloadStore: @unchecked Sendable {
    private struct Entry {
        let response: HttpResponse
        let owner: DownloadOwner
        let expires: Date
        let size: Int
    }

    private let lock = NIOLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    let maxTotalBytes: Int
    let maxEntries: Int
    let ttl: TimeInterval

    init(maxTotalBytes: Int = 128 * 1024 * 1024, maxEntries: Int = 32, ttl: TimeInterval = 60) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntries = maxEntries
        self.ttl = ttl
    }

    /// Stores `response` and returns its unguessable token (64 hex chars, URL-safe),
    /// or `nil` if it alone exceeds `maxTotalBytes`.
    func put(_ response: HttpResponse, owner: DownloadOwner, now: Date = Date()) -> String? {
        let size = response.body.byteCount
        guard size <= maxTotalBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        lock.lock()
        defer { lock.unlock() }
        evictExpired(now)
        while !order.isEmpty, entries.count >= maxEntries || totalBytes + size > maxTotalBytes {
            entries.removeValue(forKey: order.removeFirst())
        }
        entries[token] = Entry(response: response, owner: owner, expires: now.addingTimeInterval(ttl), size: size)
        order.append(token)
        return token
    }

    /// The stored response if `token` is live and `request` comes from its owner.
    /// `consume` removes it (a second call, a wrong owner never consumes: 404).
    func take(_ token: String, request: HttpRequest, consume: Bool = true, now: Date = Date()) -> HttpResponse? {
        lock.lock()
        defer { lock.unlock() }
        evictExpired(now)
        guard let entry = entries[token], entry.owner.matches(request) else { return nil }
        if consume {
            entries.removeValue(forKey: token)
            order.removeAll { $0 == token }
        }
        return entry.response
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private var totalBytes: Int { entries.values.reduce(0) { $0 + $1.size } }

    private func evictExpired(_ now: Date) {
        let expired = entries.filter { $0.value.expires <= now }.map(\.key)
        for token in expired { entries.removeValue(forKey: token) }
        if !expired.isEmpty { order.removeAll { entries[$0] == nil } }
    }
}

/// One store per `WebApplication` (keyed by identity, like `PagesRootBox`).
final class OneTimeDownloadStoreBox: @unchecked Sendable {
    private let lock = NIOLock()
    private var stores: [ObjectIdentifier: OneTimeDownloadStore] = [:]

    func store(for app: WebApplication, create: () -> OneTimeDownloadStore) -> (store: OneTimeDownloadStore, isNew: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = stores[ObjectIdentifier(app)] { return (existing, false) }
        let created = create()
        stores[ObjectIdentifier(app)] = created
        return (created, true)
    }
}
let sharedOneTimeDownloadStoreBox = OneTimeDownloadStoreBox()

extension WebApplication {
    /// The app's download store. The first call also registers
    /// `GET /_framework/dl/{token}` (once: Live Pages and blob downloads share
    /// it, neither needs the other), so call it while routes can still be added.
    @discardableResult
    func oneTimeDownloads() -> OneTimeDownloadStore {
        let (store, isNew) = sharedOneTimeDownloadStoreBox.store(for: self) { OneTimeDownloadStore() }
        if isNew {
            routeRegistry.register(method: .get, path: "/_framework/dl/{token}", auth: .none, summary: nil) { ctx in
                guard let token = ctx.request.routeValues["token"],
                      var response = store.take(token, request: ctx.request, consume: ctx.request.method != .head) else {
                    return Results.notFound()
                }
                response.headers["Cache-Control"] = "no-store"
                response.headers["X-Content-Type-Options"] = "nosniff"
                if response.headers["Content-Disposition"] == nil {
                    response.headers["Content-Disposition"] = contentDispositionHeader(fileName: "download")
                }
                response.acceptsRanges = false
                return HttpResult(response)
            }
        }
        return store
    }
}
