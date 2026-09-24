// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import SwiftCoreWeb

/// JSON view of `ServerMetricsSnapshot`, without the per-request client IPs
/// (personal data, never serialized — see `ServerMetrics.swift`'s own note).
public struct MetricsPayload: Codable, Sendable {
    public struct RecentRequest: Codable, Sendable {
        public let method: String
        public let path: String
        public let statusCode: Int
        public let durationMilliseconds: Double
        public let byteCount: Int
        public let timestamp: Date
    }

    public struct Server: Codable, Sendable {
        public let startedAt: Date?
        public let totalRequests: Int
        public let requestsPerSecond: Double
        public let statusClassCounts: [String: Int]
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
        public let recentRequests: [RecentRequest]
    }

    public struct Device: Codable, Sendable {
        public let timestamp: Date
        public let modelIdentifier: String
        public let deviceName: String
        public let systemVersion: String
        public let cpuUsagePercent: Double
        public let processThreadCount: Int
        public let appMemoryFootprintBytes: UInt64
        public let availableMemoryBytes: UInt64
        public let physicalMemoryBytes: UInt64
        public let thermalState: String
        public let batteryLevel: Float
        public let isLowPowerModeEnabled: Bool
        public let freeStorageBytes: Int64
        public let totalStorageBytes: Int64
        public let systemUptimeSeconds: TimeInterval
    }

    public let server: Server
    public let device: Device?
}

extension MetricsPayload.Server {
    init(_ snapshot: ServerMetricsSnapshot) {
        startedAt = snapshot.startedAt
        totalRequests = snapshot.totalRequests
        requestsPerSecond = snapshot.requestsPerSecond
        statusClassCounts = Dictionary(uniqueKeysWithValues: snapshot.statusClassCounts.map { (String($0.key), $0.value) })
        rateLimitedCount = snapshot.rateLimitedCount
        atCapacityCount = snapshot.atCapacityCount
        activeConnections = snapshot.activeConnections
        activeWebSockets = snapshot.activeWebSockets
        bytesIn = snapshot.bytesIn
        bytesOut = snapshot.bytesOut
        averageLatencyMilliseconds = snapshot.averageLatencyMilliseconds
        p95LatencyMilliseconds = snapshot.p95LatencyMilliseconds
        maxLatencyMilliseconds = snapshot.maxLatencyMilliseconds
        networkRebindCount = snapshot.networkRebindCount
        lastNetworkRebindAt = snapshot.lastNetworkRebindAt
        lastError = snapshot.lastError
        recentRequests = snapshot.recentRequests.map {
            MetricsPayload.RecentRequest(
                method: $0.method,
                path: $0.path,
                statusCode: $0.statusCode,
                durationMilliseconds: $0.durationMilliseconds,
                byteCount: $0.byteCount,
                timestamp: $0.timestamp
            )
        }
    }
}

extension MetricsPayload.Device {
    init(_ snapshot: DeviceSnapshot) {
        timestamp = snapshot.timestamp
        modelIdentifier = snapshot.modelIdentifier
        deviceName = snapshot.deviceName
        systemVersion = snapshot.systemVersion
        cpuUsagePercent = snapshot.cpuUsagePercent
        processThreadCount = snapshot.processThreadCount
        appMemoryFootprintBytes = snapshot.appMemoryFootprintBytes
        availableMemoryBytes = snapshot.availableMemoryBytes
        physicalMemoryBytes = snapshot.physicalMemoryBytes
        thermalState = snapshot.thermalState.dashboardDescription
        batteryLevel = snapshot.batteryLevel
        isLowPowerModeEnabled = snapshot.isLowPowerModeEnabled
        freeStorageBytes = snapshot.freeStorageBytes
        totalStorageBytes = snapshot.totalStorageBytes
        systemUptimeSeconds = snapshot.systemUptimeSeconds
    }
}

extension ProcessInfo.ThermalState {
    var dashboardDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension WebApplication {
    /// Opt-in JSON + SSE metrics endpoint (server + device), disabled unless
    /// called explicitly. Exposes device health on the LAN — protect it with
    /// this app's existing auth middleware (`auth:`) if the device isn't on
    /// a trusted network. `latestDevice` is read from `DashboardModel`
    /// (device sampling only runs while its dashboard is active); it's
    /// `nil` in the JSON/SSE payload until the dashboard has sampled once.
    @discardableResult
    public func mapMetrics(_ path: String, model: DashboardModel, auth: AuthRequirement = .none) -> Self {
        mapGet(path, auth: auth) { _ in
            let device = await model.latestDevice
            return MetricsPayload(
                server: MetricsPayload.Server(self.metrics.snapshot()),
                device: device.map(MetricsPayload.Device.init)
            )
        }
        mapSse("\(path)/stream", auth: auth) { writer in
            while !Task.isCancelled {
                let device = await model.latestDevice
                let payload = MetricsPayload(
                    server: MetricsPayload.Server(self.metrics.snapshot()),
                    device: device.map(MetricsPayload.Device.init)
                )
                let json = String(decoding: try JSONEncoder.dashboardMetrics.encode(payload), as: UTF8.self)
                try await writer.send(json)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return self
    }
}

extension JSONEncoder {
    fileprivate static let dashboardMetrics: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
