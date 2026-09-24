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

    public init(app: WebApplication) {
        self.app = app
        sampler.onSample = { [weak self] snapshot in
            self?.handleSample(snapshot)
        }
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
