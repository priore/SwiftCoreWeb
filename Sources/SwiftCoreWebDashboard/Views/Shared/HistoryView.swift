// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI

/// Segmented Live / 24h / 7d / 30d history, backed by `DashboardModel`:
/// Live reads the in-memory ring directly, the other three windows are
/// fetched from `MetricsHistory` on selection. Gaps in the stored windows
/// (app suspended) are periods with no row — `Sparkline` simply doesn't
/// plot indices it wasn't given, so callers must not synthesize zeros.
public struct HistoryView: SwiftUI.View {
    fileprivate enum Segment: String, CaseIterable, Identifiable {
        case live = "Live", last24Hours = "24h", last7Days = "7d", last30Days = "30d"
        var id: String { rawValue }
    }

    @ObservedObject private var model: DashboardModel
    @State private var selection: Segment = .live
    @State private var storedRows: [MetricsHistoryRow] = []

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some SwiftUI.View {
        VStack {
            Picker("", selection: $selection) {
                ForEach(Segment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selection) { _ in Task { await reload() } }

            Sparkline(values: cpuValues)
                .frame(height: 80)
        }
        .task { await reload() }
    }

    private var cpuValues: [Double] {
        switch selection {
        case .live: model.liveHistory.map(\.device.cpuUsagePercent)
        case .last24Hours, .last7Days, .last30Days: storedRows.map(\.averageCPUPercent)
        }
    }

    private func reload() async {
        guard let window = selection.historyWindow else { return }
        storedRows = await model.historyRows(for: window)
    }
}

private extension HistoryView.Segment {
    var historyWindow: MetricsHistory.HistoryWindow? {
        switch self {
        case .live: nil
        case .last24Hours: .last24Hours
        case .last7Days: .last7Days
        case .last30Days: .last30Days
        }
    }
}
