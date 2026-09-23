// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Early-gate traffic protection (the early-gate rate limiting design): a token-bucket rate limiter keyed by
/// client IP, and a connection-count gate. Both run before the middleware
/// pipeline and before any request body bytes are read, so an over-limit
/// client is rejected without the cost of parsing its request.
///
/// An actor, per the concurrency/lifecycle/network watchdog design: no locks, safe under Swift 6 strict concurrency.
actor RateLimiter {
    private struct Bucket {
        var tokens: Double
        var lastRefill: DispatchTime
    }

    private let options: RateLimitOptions
    private var buckets: [String: Bucket] = [:]
    /// Tracks insertion order for LRU eviction once `maxTrackedClients` is hit.
    private var lruOrder: [String] = []

    init(options: RateLimitOptions) {
        self.options = options
    }

    /// Returns `true` if the request from `clientIP` is allowed, consuming
    /// one token. Loopback is exempt when `exemptLoopback` is set (default).
    func allow(clientIP: String) -> Bool {
        if options.exemptLoopback, isLoopback(clientIP) {
            return true
        }

        let now = DispatchTime.now()
        if var bucket = buckets[clientIP] {
            let elapsedSeconds = Double(now.uptimeNanoseconds &- bucket.lastRefill.uptimeNanoseconds) / 1e9
            bucket.tokens = min(Double(options.capacity), bucket.tokens + elapsedSeconds * options.refillPerSecond)
            bucket.lastRefill = now
            touch(clientIP)

            guard bucket.tokens >= 1 else {
                buckets[clientIP] = bucket
                return false
            }
            bucket.tokens -= 1
            buckets[clientIP] = bucket
            return true
        }

        evictIfNeeded()
        buckets[clientIP] = Bucket(tokens: Double(options.capacity) - 1, lastRefill: now)
        lruOrder.append(clientIP)
        return true
    }

    /// Prunes buckets that have been idle long enough to be back at full
    /// capacity, keeping memory bounded on long-running devices. Call
    /// periodically (see `ConnectionGate.startPruning`).
    func pruneIdle() {
        let now = DispatchTime.now()
        buckets = buckets.filter { _, bucket in
            let elapsedSeconds = Double(now.uptimeNanoseconds &- bucket.lastRefill.uptimeNanoseconds) / 1e9
            // Idle long enough to have refilled to capacity: safe to drop,
            // a fresh bucket at full capacity is equivalent.
            return elapsedSeconds * options.refillPerSecond < Double(options.capacity)
        }
        lruOrder.removeAll { buckets[$0] == nil }
    }

    private func touch(_ clientIP: String) {
        if let index = lruOrder.firstIndex(of: clientIP) {
            lruOrder.remove(at: index)
        }
        lruOrder.append(clientIP)
    }

    private func evictIfNeeded() {
        // ponytail: linear removeFirst under the cap check, fine at
        // maxTrackedClients scale (thousands); switch to a proper LRU
        // structure only if profiling shows this actually matters.
        while buckets.count >= options.maxTrackedClients, !lruOrder.isEmpty {
            let oldest = lruOrder.removeFirst()
            buckets.removeValue(forKey: oldest)
        }
    }

    private func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip == "localhost"
    }
}

/// Tracks the number of concurrently open connections and enforces
/// `ServerOptions.maxConcurrentConnections` (the early-gate rate limiting design): beyond the cap, new
/// connections are rejected with `503` and closed immediately.
actor ConnectionGate {
    private let maxConcurrent: Int
    private var current = 0

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    /// Attempts to reserve a connection slot. Returns `false` if at capacity.
    func tryAcquire() -> Bool {
        guard current < maxConcurrent else { return false }
        current += 1
        return true
    }

    func release() {
        current = max(0, current - 1)
    }
}
