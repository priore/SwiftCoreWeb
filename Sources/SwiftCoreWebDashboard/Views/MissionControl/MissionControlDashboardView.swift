// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI

/// Style A — Mission Control: dark NOC-style grid, dense monospace tiles
/// with a value + sparkline + status LED each (see the plan's mockup A).
public struct MissionControlDashboardView: SwiftUI.View {
    @ObservedObject private var model: DashboardModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some SwiftUI.View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tiles) { tile in
                    MissionControlTile(tile: tile)
                }
            }
            .padding()

            if let server = model.latestServer {
                RequestLogView(requests: server.recentRequests)
                    .frame(height: 200)
            }

            HistoryView(model: model)
                .padding(.horizontal)
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .task { model.startSampling() }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: horizontalSizeClass == .regular ? 4 : 2)
    }

    private var tiles: [MissionControlTile.Data] {
        guard let device = model.latestDevice, let server = model.latestServer else { return [] }
        let cpuHistory = model.liveHistory.map(\.device.cpuUsagePercent)
        let reqHistory = model.liveHistory.map(\.server.requestsPerSecond)

        return [
            .init(title: "CPU", value: String(format: "%.0f%%", device.cpuUsagePercent), history: cpuHistory, isNominal: device.cpuUsagePercent < 80),
            .init(title: "MEM", value: ByteCountFormatter.string(fromByteCount: Int64(device.appMemoryFootprintBytes), countStyle: .memory), history: [], isNominal: true),
            .init(title: "REQ/S", value: String(format: "%.1f", server.requestsPerSecond), history: reqHistory, isNominal: true),
            .init(title: "LATENCY", value: String(format: "%.0f ms", server.averageLatencyMilliseconds), history: [], isNominal: server.averageLatencyMilliseconds < 200),
            .init(title: "CONN", value: "\(server.activeConnections)", history: [], isNominal: true),
            .init(title: "THERMAL", value: device.thermalState.label, history: [], isNominal: device.thermalState == .nominal || device.thermalState == .fair),
            .init(title: "ERRORS 5XX", value: "\((server.statusClassCounts[5] ?? 0))", history: [], isNominal: (server.statusClassCounts[5] ?? 0) == 0),
            .init(title: "BATTERY", value: String(format: "%.0f%%", device.batteryLevel * 100), history: [], isNominal: device.batteryLevel > 0.2 || device.batteryLevel < 0),
        ]
    }
}

private struct MissionControlTile: SwiftUI.View {
    struct Data: Identifiable {
        let title: String
        let value: String
        let history: [Double]
        let isNominal: Bool
        var id: String { title }
    }

    let tile: Data

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tile.title)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(tile.isNominal ? .green : .red)
                    .frame(width: 6, height: 6)
            }
            Text(tile.value)
                .font(.system(.title2, design: .monospaced))
                .bold()
            if tile.history.count > 1 {
                Sparkline(values: tile.history, lineColor: tile.isNominal ? .green : .red)
                    .frame(height: 24)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }
}

private extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "NOMINAL"
        case .fair: "FAIR"
        case .serious: "SERIOUS"
        case .critical: "CRITICAL"
        @unknown default: "?"
        }
    }
}
