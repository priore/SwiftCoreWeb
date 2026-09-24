// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI

/// Style B — Native Cards: grouped iOS look (Health/Settings-style), gauge
/// rings for CPU/RAM/disk/battery, a header card with server status + URL +
/// QR (see the plan's mockup B). Follows system light/dark and Dynamic Type.
public struct NativeCardsDashboardView: SwiftUI.View {
    @ObservedObject private var model: DashboardModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some SwiftUI.View {
        ScrollView {
            VStack(spacing: 16) {
                serverCard
                ringsGrid
                HistoryView(model: model)
                if let server = model.latestServer {
                    RequestLogView(requests: server.recentRequests)
                        .frame(height: 200)
                }
            }
            .padding()
        }
        .task { model.startSampling() }
    }

    private var serverCard: some SwiftUI.View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(model.isServerRunning ? .green : .red)
                    .frame(width: 10, height: 10)
                Text(model.isServerRunning ? "Running" : "Stopped")
                    .font(.headline)
                Spacer()
                controls
            }
            if let url = model.serverURL {
                Text(url.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                QRCodeView(url: url)
                    .frame(width: 96, height: 96)
            }
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(16)
    }

    private var controls: some SwiftUI.View {
        HStack(spacing: 16) {
            Button(model.isServerRunning ? "Stop" : "Start") {
                Task { model.isServerRunning ? await model.stopServer() : await model.startServer() }
            }
            Button("Restart") {
                Task { await model.restartServer() }
            }
            .disabled(!model.isServerRunning)
        }
        .buttonStyle(.bordered)
    }

    private var ringsGrid: some SwiftUI.View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: horizontalSizeClass == .regular ? 4 : 2), spacing: 16) {
            if let device = model.latestDevice {
                RingCard(title: "CPU", value: device.cpuUsagePercent / 100, label: String(format: "%.0f%%", device.cpuUsagePercent))
                RingCard(title: "Storage", value: storageUsedFraction(device), label: ByteCountFormatter.string(fromByteCount: device.freeStorageBytes, countStyle: .file) + " free")
                RingCard(title: "Battery", value: Double(max(device.batteryLevel, 0)), label: device.batteryLevel < 0 ? "—" : String(format: "%.0f%%", device.batteryLevel * 100))
                RingCard(title: "Memory", value: memoryFraction(device), label: ByteCountFormatter.string(fromByteCount: Int64(device.appMemoryFootprintBytes), countStyle: .memory))
            }
        }
    }

    private func storageUsedFraction(_ device: DeviceSnapshot) -> Double {
        guard device.totalStorageBytes > 0 else { return 0 }
        let used = device.totalStorageBytes - device.freeStorageBytes
        return Double(used) / Double(device.totalStorageBytes)
    }

    private func memoryFraction(_ device: DeviceSnapshot) -> Double {
        guard device.physicalMemoryBytes > 0 else { return 0 }
        return Double(device.appMemoryFootprintBytes) / Double(device.physicalMemoryBytes)
    }
}

private struct RingCard: SwiftUI.View {
    let title: String
    let value: Double
    let label: String

    var body: some SwiftUI.View {
        VStack(spacing: 8) {
            ZStack {
                GaugeRing(progress: value)
                    .frame(width: 56, height: 56)
                Text(label)
                    .font(.caption2)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
        .cornerRadius(16)
    }
}
