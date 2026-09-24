// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI
import UIKit
import SwiftCoreWeb

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
                if let server = model.latestServer {
                    trafficGroup(server)
                }
                if let device = model.latestDevice {
                    deviceGroup(device, server: model.latestServer)
                }
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
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = url.absoluteString
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
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
                RingCard(title: "CPU", value: device.cpuUsagePercent / 100,
                          ringLabel: String(format: "%.0f%%", device.cpuUsagePercent), sub: nil)
                RingCard(title: "Storage free", value: storageUsedFraction(device),
                          ringLabel: String(format: "%.0f%%", storageUsedFraction(device) * 100),
                          sub: ByteCountFormatter.string(fromByteCount: device.freeStorageBytes, countStyle: .memory))
                RingCard(title: "Battery", value: Double(max(device.batteryLevel, 0)),
                          ringLabel: device.batteryLevel < 0 ? "—" : String(format: "%.0f%%", device.batteryLevel * 100), sub: nil)
                RingCard(title: "Memory", value: memoryFraction(device),
                          ringLabel: String(format: "%.0f%%", memoryFraction(device) * 100),
                          sub: ByteCountFormatter.string(fromByteCount: Int64(device.appMemoryFootprintBytes), countStyle: .memory))
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

    // MARK: - Traffic / Device grouped rows (mockup B's "settings-style" groups)

    private func trafficGroup(_ server: ServerMetricsSnapshot) -> some SwiftUI.View {
        GroupedRows(title: "Traffic") {
            InfoRow(icon: "arrow.up.arrow.down", tint: .accentColor,
                    label: "Requests / sec", value: String(format: "%.0f/s", server.requestsPerSecond))
            InfoRow(icon: "timer", tint: .green,
                    label: "Latency (p95)", value: String(format: "%.0f ms", server.p95LatencyMilliseconds))
            InfoRow(icon: "arrow.left.arrow.right", tint: .secondary,
                    label: "Active connections", value: "\(server.activeConnections)")
            InfoRow(icon: "exclamationmark.triangle", tint: .orange,
                    label: "Rate-limited (429)", value: "\(server.rateLimitedCount)")
            InfoRow(icon: "checkmark.circle", tint: .green,
                    label: "Server errors (5xx)", value: "\(server.statusClassCounts[5] ?? 0)")
        }
    }

    private func deviceGroup(_ device: DeviceSnapshot, server: ServerMetricsSnapshot?) -> some SwiftUI.View {
        GroupedRows(title: "Device") {
            InfoRow(icon: "thermometer", tint: thermalTint(device.thermalState),
                    label: "Thermal state", value: thermalLabel(device.thermalState))
            if let server {
                InfoRow(icon: "arrow.triangle.2.circlepath", tint: .secondary,
                        label: "Network rebinds", value: "\(server.networkRebindCount)")
            }
        }
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func thermalTint(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious, .critical: return .red
        @unknown default: return .secondary
        }
    }
}

/// A settings-style grouped card: a section title followed by a rounded list
/// of rows, each row a `HStack` builder result — mirrors mockup B's
/// `.group-title` + `.group`/`.row` CSS classes.
private struct GroupedRows<Content: SwiftUI.View>: SwiftUI.View {
    let title: String
    @SwiftUI.ViewBuilder let content: Content

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .background(.regularMaterial)
            .cornerRadius(14)
        }
    }
}

private struct InfoRow: SwiftUI.View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some SwiftUI.View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint)
                .cornerRadius(8)
                .font(.system(size: 14))
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        Divider().padding(.leading, 58)
    }
}

private struct RingCard: SwiftUI.View {
    let title: String
    let value: Double
    /// Short text inside the ring (a percentage — always fits one line).
    let ringLabel: String
    /// Longer value shown below the title (e.g. "416 GB free"), when the
    /// ring's own percentage isn't the most useful number to read at a glance.
    let sub: String?

    var body: some SwiftUI.View {
        HStack(spacing: 14) {
            ZStack {
                GaugeRing(progress: value)
                    .frame(width: 56, height: 56)
                Text(ringLabel)
                    .font(.caption2)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sub ?? ringLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(16)
    }
}
