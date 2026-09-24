// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import SwiftCoreWeb

/// Backs both dashboard styles (Mission Control / Native Cards) with the
/// same data: server metrics polled from `app.metrics`, device health from
/// `DeviceSampler`, and a 5-minute live ring of both for the sparklines.
/// `@MainActor`/`ObservableObject` rather than `@Observable`: deployment
/// target is iOS 15 (see swift-style.md's SwiftUI exception note for this
/// target).
@MainActor
public final class DashboardModel: ObservableObject {
    /// One tick of the live ring (device + server, sampled together at 1 Hz).
    public struct LiveSample: Sendable {
        public let timestamp: Date
        public let device: DeviceSnapshot
        public let server: ServerMetricsSnapshot
    }

    @Published public private(set) var latestDevice: DeviceSnapshot?
    @Published public private(set) var latestServer: ServerMetricsSnapshot?
    @Published public private(set) var liveHistory: [LiveSample] = []
    @Published public private(set) var isServerRunning = false
    @Published public private(set) var lastActionError: String?

    private static let liveHistoryLimit = 300 // 5 minutes at 1 Hz

    public let app: WebApplication
    private let sampler = DeviceSampler()
    private let history: MetricsHistory?
    private var previousServerSnapshot: ServerMetricsSnapshot?

    /// `history` is `nil` when opening the SQLite database failed (e.g. a
    /// full disk) — the live dashboard still works, it just has no
    /// 24h/7d/30d views for this session, rather than crashing on startup.
    public init(app: WebApplication, history: MetricsHistory?) {
        self.app = app
        self.history = history
        sampler.onSample = { [weak self] snapshot in
            self?.handleSample(snapshot)
        }
    }

    /// Convenience initializer that opens the default on-disk history
    /// itself, for callers who don't need to inject a test double.
    public static func withDefaultHistory(app: WebApplication, configuration: DashboardConfiguration = .default) async -> DashboardModel {
        let history = try? await MetricsHistory(configuration: configuration)
        return DashboardModel(app: app, history: history)
    }

    /// Starts device sampling. Call once the dashboard view appears; safe to
    /// call again (`DeviceSampler.start()` restarts cleanly).
    public func startSampling() {
        sampler.start()
        isServerRunning = app.isRunning
    }

    public func stopSampling() {
        sampler.stop()
    }

    private func handleSample(_ device: DeviceSnapshot) {
        latestDevice = device
        let server = app.metrics.snapshot()
        latestServer = server
        isServerRunning = app.isRunning

        liveHistory.append(LiveSample(timestamp: device.timestamp, device: device, server: server))
        if liveHistory.count > Self.liveHistoryLimit {
            liveHistory.removeFirst()
        }

        if let history {
            let row = Self.historyRow(device: device, server: server, previousServer: previousServerSnapshot)
            Task { try? await history.record(row) }
        }
        previousServerSnapshot = server
    }

    /// `ServerMetricsSnapshot`'s counters are cumulative since server start,
    /// but a history row is "how much happened in this one-second sample" —
    /// so requests/bytes/error-class counts are diffed against the previous
    /// sample (0 on the very first sample, or after a restart resets the
    /// counters lower than `previousServer`, since `max(0, …)` floors it).
    private static func historyRow(device: DeviceSnapshot, server: ServerMetricsSnapshot, previousServer: ServerMetricsSnapshot?) -> MetricsHistoryRow {
        func delta(_ current: Int, _ previous: Int) -> Int { max(0, current - previous) }

        let requestDelta = delta(server.totalRequests, previousServer?.totalRequests ?? server.totalRequests)
        let clientErrorDelta = delta(server.statusClassCounts[4] ?? 0, previousServer?.statusClassCounts[4] ?? (server.statusClassCounts[4] ?? 0))
        let serverErrorDelta = delta(server.statusClassCounts[5] ?? 0, previousServer?.statusClassCounts[5] ?? (server.statusClassCounts[5] ?? 0))
        let bytesInDelta = delta(server.bytesIn, previousServer?.bytesIn ?? server.bytesIn)
        let bytesOutDelta = delta(server.bytesOut, previousServer?.bytesOut ?? server.bytesOut)

        return MetricsHistoryRow(
            timestamp: device.timestamp,
            averageCPUPercent: device.cpuUsagePercent,
            maxCPUPercent: device.cpuUsagePercent,
            averageMemoryBytes: device.appMemoryFootprintBytes,
            maxMemoryBytes: device.appMemoryFootprintBytes,
            requestCount: requestDelta,
            clientErrorCount: clientErrorDelta,
            serverErrorCount: serverErrorDelta,
            bytesIn: bytesInDelta,
            bytesOut: bytesOutDelta,
            averageLatencyMilliseconds: server.averageLatencyMilliseconds,
            p95LatencyMilliseconds: server.p95LatencyMilliseconds,
            maxThermalStateRawValue: device.thermalState.rawValue,
            minBatteryLevel: device.batteryLevel,
            maxActiveConnections: server.activeConnections
        )
    }

    /// A window's aggregated history rows (Live is `liveHistory`, this
    /// serves the 24h/7d/30d segmented view). Empty when no history store
    /// was available at init.
    public func historyRows(for window: MetricsHistory.HistoryWindow) async -> [MetricsHistoryRow] {
        guard let history else { return [] }
        return (try? await history.rows(for: window)) ?? []
    }

    // MARK: - Server controls

    public func stopServer() async {
        do {
            try await app.stopAsync(timeout: 5)
            isServerRunning = false
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    public func startServer() async {
        Task.detached { [app] in
            try? await app.runAsync()
        }
        while !app.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        isServerRunning = true
    }

    public func restartServer() async {
        await stopServer()
        await startServer()
    }

    /// The URL to reach this server from another device on the LAN, for the
    /// QR code and the header. `app.urls` is populated by `runAsync()` once
    /// the listener is bound, so this is `nil` until the server is running.
    public var serverURL: URL? {
        app.urls.first.flatMap(URL.init(string:))
    }
}
