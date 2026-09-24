// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers

/// One recent request, kept only in memory for the live request log
/// (the on-device dashboard design). Never persisted: `clientIP` is
/// personal data and the ring is dropped when the process exits.
public struct RecordedRequest: Sendable {
    public let method: String
    public let path: String
    public let statusCode: Int
    public let durationMilliseconds: Double
    public let byteCount: Int
    public let clientIP: String
    public let timestamp: Date
}

/// Why a connection or request was rejected, for the counters below.
public enum RejectionReason: Sendable {
    case atCapacity
    case rateLimited
}

/// Point-in-time read of `ServerMetrics`, safe to hand across actor/thread
/// boundaries and to serialize (the opt-in `mapMetrics` JSON endpoint).
public struct ServerMetricsSnapshot: Sendable {
    public let startedAt: Date?
    public let totalRequests: Int
    public let requestsPerSecond: Double
    public let statusClassCounts: [Int: Int] // keyed by 2/3/4/5 (hundreds digit)
    public let rateLimitedCount: Int
    public let atCapacityCount: Int
    public let activeConnections: Int
    public let activeWebSockets: Int
    public let bytesIn: Int
    public let bytesOut: Int
    public let averageLatencyMilliseconds: Double
    public let p95LatencyMilliseconds: Double
    public let maxLatencyMilliseconds: Double
    public let networkRebindCount: Int
    public let lastNetworkRebindAt: Date?
    public let lastError: String?
    public let recentRequests: [RecordedRequest]
}

/// In-memory counters and a fixed-size ring of recent requests, fed by
/// `ServerEngine` and `RequestDispatcher.dispatch` (so both the live server
/// and `TestHost` are counted). One lock, incremented a handful of times per
/// request — ponytail: no toggle to disable this, the cost is a few counter
/// bumps under a lock, not worth a config flag.
public final class ServerMetrics: @unchecked Sendable {
    private struct State {
        var startedAt: Date?
        var totalRequests = 0
        var statusClassCounts: [Int: Int] = [:]
        var rateLimitedCount = 0
        var atCapacityCount = 0
        var activeConnections = 0
        var activeWebSockets = 0
        var bytesIn = 0
        var bytesOut = 0
        var recentLatenciesMilliseconds: [Double] = []
        var networkRebindCount = 0
        var lastNetworkRebindAt: Date?
        var lastError: String?
        var recentRequests: [RecordedRequest] = []
    }

    private static let recentRequestsLimit = 200
    private static let recentLatenciesLimit = 200

    private let box = NIOLockedValueBox(State())

    public init() {}

    public func markStarted() {
        box.withLockedValue { $0.startedAt = Date() }
    }

    public func markStopped() {
        box.withLockedValue { $0.startedAt = nil }
    }

    public func recordRebind() {
        box.withLockedValue {
            $0.networkRebindCount += 1
            $0.lastNetworkRebindAt = Date()
        }
    }

    public func recordRejected(_ reason: RejectionReason) {
        box.withLockedValue {
            switch reason {
            case .atCapacity: $0.atCapacityCount += 1
            case .rateLimited: $0.rateLimitedCount += 1
            }
        }
    }

    public func connectionOpened() {
        box.withLockedValue { $0.activeConnections += 1 }
    }

    public func connectionClosed() {
        box.withLockedValue { $0.activeConnections = max(0, $0.activeConnections - 1) }
    }

    public func webSocketOpened() {
        box.withLockedValue { $0.activeWebSockets += 1 }
    }

    public func webSocketClosed() {
        box.withLockedValue { $0.activeWebSockets = max(0, $0.activeWebSockets - 1) }
    }

    public func recordError(_ message: String) {
        box.withLockedValue { $0.lastError = message }
    }

    /// Records one completed request: updates counters, the latency ring
    /// (for average/p95/max), and the recent-requests ring (for the live
    /// request log). `clientIP` never leaves memory.
    public func recordRequest(
        method: String,
        path: String,
        statusCode: Int,
        durationMilliseconds: Double,
        byteCount: Int,
        clientIP: String
    ) {
        box.withLockedValue { state in
            state.totalRequests += 1
            let statusClass = statusCode / 100
            state.statusClassCounts[statusClass, default: 0] += 1
            state.bytesOut += byteCount

            state.recentLatenciesMilliseconds.append(durationMilliseconds)
            if state.recentLatenciesMilliseconds.count > Self.recentLatenciesLimit {
                state.recentLatenciesMilliseconds.removeFirst()
            }

            let record = RecordedRequest(
                method: method,
                path: path,
                statusCode: statusCode,
                durationMilliseconds: durationMilliseconds,
                byteCount: byteCount,
                clientIP: clientIP,
                timestamp: Date()
            )
            state.recentRequests.append(record)
            if state.recentRequests.count > Self.recentRequestsLimit {
                state.recentRequests.removeFirst()
            }
        }
    }

    public func recordBytesIn(_ count: Int) {
        box.withLockedValue { $0.bytesIn += count }
    }

    public func snapshot() -> ServerMetricsSnapshot {
        box.withLockedValue { state in
            let latencies = state.recentLatenciesMilliseconds.sorted()
            let average = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
            let p95Index = latencies.isEmpty ? 0 : min(latencies.count - 1, Int(Double(latencies.count) * 0.95))
            let p95 = latencies.isEmpty ? 0 : latencies[p95Index]
            let max = latencies.last ?? 0

            let requestsPerSecond: Double
            if let startedAt = state.startedAt {
                let elapsed = Date().timeIntervalSince(startedAt)
                requestsPerSecond = elapsed > 0 ? Double(state.totalRequests) / elapsed : 0
            } else {
                requestsPerSecond = 0
            }

            return ServerMetricsSnapshot(
                startedAt: state.startedAt,
                totalRequests: state.totalRequests,
                requestsPerSecond: requestsPerSecond,
                statusClassCounts: state.statusClassCounts,
                rateLimitedCount: state.rateLimitedCount,
                atCapacityCount: state.atCapacityCount,
                activeConnections: state.activeConnections,
                activeWebSockets: state.activeWebSockets,
                bytesIn: state.bytesIn,
                bytesOut: state.bytesOut,
                averageLatencyMilliseconds: average,
                p95LatencyMilliseconds: p95,
                maxLatencyMilliseconds: max,
                networkRebindCount: state.networkRebindCount,
                lastNetworkRebindAt: state.lastNetworkRebindAt,
                lastError: state.lastError,
                recentRequests: state.recentRequests
            )
        }
    }
}
