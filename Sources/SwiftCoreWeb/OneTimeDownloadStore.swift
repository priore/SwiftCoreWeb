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
/// In-memory bodies count against `maxTotalBytes`. A disk-backed entry (`ownedFile`, a blob
/// spooled to disk) counts against a separate disk budget, `maxDiskBytes` / `maxDiskEntries`, and
/// its file is deleted when the entry is taken (after it is sent), expires or is evicted. Other
/// `.file` / `.stream` entries cost no RAM until served and are never deleted by the store.
/// When full the oldest entries are dropped.
///
/// ponytail: an expired or evicted entry is noticed on the next `put`/`take`, and a taken one whose
/// response never reaches the engine leaks its file until the startup sweep (1 day).
final class OneTimeDownloadStore: @unchecked Sendable {
    private struct Entry {
        let response: HttpResponse
        let owner: DownloadOwner
        let expires: Date
        let size: Int
        /// A file the store owns and deletes (the entry's response is a `.file` of exactly this path).
        let ownedFile: String?
        let diskSize: Int
    }

    private let lock = NIOLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    let maxTotalBytes: Int
    let maxEntries: Int
    /// Disk budget for entries with an `ownedFile`: total bytes and number of entries.
    let maxDiskBytes: Int
    let maxDiskEntries: Int
    let ttl: TimeInterval

    init(maxTotalBytes: Int = 128 * 1024 * 1024, maxEntries: Int = 32, maxDiskBytes: Int = 512 * 1024 * 1024, maxDiskEntries: Int = 8, ttl: TimeInterval = 60) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntries = maxEntries
        self.maxDiskBytes = maxDiskBytes
        self.maxDiskEntries = maxDiskEntries
        self.ttl = ttl
    }

    /// Stores `response` and returns its unguessable token (64 hex chars, URL-safe),
    /// or `nil` if it alone exceeds `maxTotalBytes` (or, for an `ownedFile`, `maxDiskBytes`):
    /// then the caller still owns the file.
    func put(_ response: HttpResponse, owner: DownloadOwner, ownedFile: String? = nil, now: Date = Date()) -> String? {
        let size = response.body.byteCount
        let diskSize = ownedFile.map { UploadStorage.size(of: URL(fileURLWithPath: $0)) } ?? 0
        guard size <= maxTotalBytes, diskSize <= maxDiskBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        lock.lock()
        defer { lock.unlock() }
        evictExpired(now)
        // Disk pressure evicts the oldest disk-backed entry (dropping in-memory ones frees no disk);
        // memory pressure the oldest of all.
        while let oldest = order.first {
            let disk = entries.values.filter { $0.ownedFile != nil }
            let diskFull = ownedFile != nil && (disk.count >= maxDiskEntries || disk.reduce(0) { $0 + $1.diskSize } + diskSize > maxDiskBytes)
            let memoryFull = entries.count >= maxEntries || totalBytes + size > maxTotalBytes
            guard diskFull || memoryFull else { break }
            let victim = (diskFull ? order.first { entries[$0]?.ownedFile != nil } : nil) ?? oldest
            order.removeAll { $0 == victim }
            discard(victim)
        }
        entries[token] = Entry(response: response, owner: owner, expires: now.addingTimeInterval(ttl), size: size, ownedFile: ownedFile, diskSize: diskSize)
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
        var response = entry.response
        if consume {
            entries.removeValue(forKey: token)
            order.removeAll { $0 == token }
            // The file must outlive this call: the engine streams it after the handler returns.
            if let file = entry.ownedFile { response.onSent = { try? FileManager.default.removeItem(atPath: file) } }
        }
        return response
    }

    /// Removes an entry that was not served, deleting the file it owns.
    private func discard(_ token: String) {
        if let file = entries.removeValue(forKey: token)?.ownedFile { try? FileManager.default.removeItem(atPath: file) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private var totalBytes: Int { entries.values.reduce(0) { $0 + $1.size } }

    private func evictExpired(_ now: Date) {
        let expired = entries.filter { $0.value.expires <= now }.map(\.key)
        for token in expired { discard(token) }
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
                if ctx.request.method == .head { response.onSent = nil } // a HEAD does not consume the entry or its file
                return HttpResult(response)
            }
        }
        return store
    }
}
