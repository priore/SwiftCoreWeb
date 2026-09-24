// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWebDashboard

final class MetricsHistoryTests: XCTestCase {
    /// 31 days of synthetic minute samples, fed in one at a time as if a
    /// day had really passed (`record` rolls up/prunes relative to each
    /// sample's own timestamp) — asserts the plan's bound: retention alone
    /// keeps each table at or under its row cap (≤1440/168/30), never
    /// growing unbounded.
    func testThirtyOneDaysOfSamplesRollUpAndPruneToRetentionBounds() async throws {
        let tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrics-history-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDBURL) }

        let history = try await MetricsHistory(fileURL: tempDBURL, configuration: .default)

        let start = Date(timeIntervalSince1970: 0)
        let totalMinutes = 31 * 24 * 60
        // Every simulated minute, not every second: a real dashboard would
        // buffer 60 per-second samples into a minute row itself, but this
        // test only needs to exercise rollup/prune, not the buffering.
        for minuteIndex in 0..<totalMinutes {
            let timestamp = start.addingTimeInterval(Double(minuteIndex) * 60)
            try await history.record(Self.syntheticRow(at: timestamp))
        }

        let minuteRows = try await history.rows(for: .last24Hours)
        let hourRows = try await history.rows(for: .last7Days)
        let dayRows = try await history.rows(for: .last30Days)

        XCTAssertLessThanOrEqual(minuteRows.count, 1440)
        XCTAssertLessThanOrEqual(hourRows.count, 168)
        XCTAssertLessThanOrEqual(dayRows.count, 30)
    }

    private static func syntheticRow(at timestamp: Date) -> MetricsHistoryRow {
        MetricsHistoryRow(
            timestamp: timestamp,
            averageCPUPercent: 10,
            maxCPUPercent: 20,
            averageMemoryBytes: 100_000_000,
            maxMemoryBytes: 120_000_000,
            requestCount: 5,
            clientErrorCount: 0,
            serverErrorCount: 0,
            bytesIn: 1000,
            bytesOut: 2000,
            averageLatencyMilliseconds: 12,
            p95LatencyMilliseconds: 25,
            maxThermalStateRawValue: 0,
            minBatteryLevel: 0.8,
            maxActiveConnections: 3
        )
    }
}
