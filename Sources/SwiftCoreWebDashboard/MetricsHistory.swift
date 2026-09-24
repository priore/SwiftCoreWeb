// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import SQLite3

/// Retention windows for the three rollup granularities. Defaults match the
/// plan: 24h at minute resolution, 7 days at hour resolution, 30 days at day
/// resolution — bounding the table sizes by construction (≤1440+168+30 rows).
public struct DashboardConfiguration: Sendable {
    public var minuteRetentionSeconds: TimeInterval
    public var hourRetentionSeconds: TimeInterval
    public var dayRetentionSeconds: TimeInterval

    public static let `default` = DashboardConfiguration(
        minuteRetentionSeconds: 24 * 3600,
        hourRetentionSeconds: 7 * 24 * 3600,
        dayRetentionSeconds: 30 * 24 * 3600
    )

    public init(minuteRetentionSeconds: TimeInterval, hourRetentionSeconds: TimeInterval, dayRetentionSeconds: TimeInterval) {
        self.minuteRetentionSeconds = minuteRetentionSeconds
        self.hourRetentionSeconds = hourRetentionSeconds
        self.dayRetentionSeconds = dayRetentionSeconds
    }
}

/// One aggregated row, whatever the granularity — averages/maxes/mins over
/// the samples that fed it. No client IPs, no paths: this is what's safe to
/// keep on disk (see the plan's privacy note).
public struct MetricsHistoryRow: Sendable {
    public let timestamp: Date
    public let averageCPUPercent: Double
    public let maxCPUPercent: Double
    public let averageMemoryBytes: UInt64
    public let maxMemoryBytes: UInt64
    public let requestCount: Int
    public let clientErrorCount: Int // 4xx
    public let serverErrorCount: Int // 5xx
    public let bytesIn: Int
    public let bytesOut: Int
    public let averageLatencyMilliseconds: Double
    public let p95LatencyMilliseconds: Double
    public let maxThermalStateRawValue: Int
    public let minBatteryLevel: Float
    public let maxActiveConnections: Int
}

/// SQLite-backed history for the dashboard's Live / 24h / 7d / 30d views.
/// System `libsqlite3` only (no SPM dependency), one file in
/// `Application Support/SwiftCoreWeb/metrics.sqlite`, excluded from backup.
///
/// An `actor` rather than a lock: every call already does file I/O, so
/// serializing through actor isolation costs nothing extra over a lock and
/// reads better at the call site (`await history.record(...)`).
public actor MetricsHistory {
    // `nonisolated(unsafe)`: `OpaquePointer` isn't `Sendable`, and `deinit`
    // on an actor is always nonisolated, so it needs unsynchronized access
    // to close the handle. Safe because every other access goes through
    // actor-isolated methods, and deinit only runs once nothing else holds
    // a reference to this actor.
    private nonisolated(unsafe) var db: OpaquePointer?
    private let configuration: DashboardConfiguration

    /// In-memory buffer of the current minute's 1 Hz samples, flushed to
    /// `samples_minute` by `flushMinuteIfNeeded()`.
    private var minuteBuffer: [MetricsHistoryRow] = []
    private var currentMinuteStart: Date?

    private static let schemaVersion: Int32 = 1

    public init(configuration: DashboardConfiguration = .default) async throws {
        self.configuration = configuration
        let url = try Self.databaseURL()
        try open(at: url.path)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA auto_vacuum=INCREMENTAL;")
        try migrateIfNeeded()
        try Self.excludeFromBackup(url)
    }

    /// Test/tooling entry point: an explicit file URL instead of the app's
    /// real Application Support directory (see `MetricsHistoryTests`, which
    /// exercises 31 days of synthetic rollup/prune in a temp directory).
    public init(fileURL: URL, configuration: DashboardConfiguration = .default) async throws {
        self.configuration = configuration
        try open(at: fileURL.path)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA auto_vacuum=INCREMENTAL;")
        try migrateIfNeeded()
    }

    private func open(at path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw MetricsHistoryError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static func databaseURL() throws -> URL {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SwiftCoreWeb", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("metrics.sqlite")
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    // MARK: - Schema

    private func migrateIfNeeded() throws {
        let currentVersion = try queryUserVersion()
        guard currentVersion < Self.schemaVersion else { return }

        let createTable = { (name: String) in
            """
            CREATE TABLE IF NOT EXISTS \(name) (
                ts INTEGER PRIMARY KEY,
                avg_cpu REAL, max_cpu REAL,
                avg_mem INTEGER, max_mem INTEGER,
                request_count INTEGER, client_error_count INTEGER, server_error_count INTEGER,
                bytes_in INTEGER, bytes_out INTEGER,
                avg_latency_ms REAL, p95_latency_ms REAL,
                max_thermal_state INTEGER, min_battery_level REAL, max_active_connections INTEGER
            );
            """
        }
        try exec(createTable("samples_minute"))
        try exec(createTable("samples_hour"))
        try exec(createTable("samples_day"))
        try exec("PRAGMA user_version = \(Self.schemaVersion);")
    }

    private func queryUserVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            throw MetricsHistoryError.queryFailed(lastErrorMessage())
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: - Ingest

    /// Buffers one 1 Hz sample; once a full minute has accumulated (or a
    /// later sample crosses into the next minute), aggregates the buffer
    /// into one `samples_minute` row and clears it. Call this once per
    /// second from `DashboardModel`.
    public func record(_ row: MetricsHistoryRow) throws {
        let minuteStart = Self.flooredToMinute(row.timestamp)
        if let currentMinuteStart, minuteStart != currentMinuteStart {
            try flushMinuteBuffer(at: currentMinuteStart)
        }
        currentMinuteStart = minuteStart
        minuteBuffer.append(row)
        try rollupHourAndDayIfNeeded(now: row.timestamp)
        try pruneExpired(now: row.timestamp)
    }

    private func flushMinuteBuffer(at minuteStart: Date) throws {
        guard !minuteBuffer.isEmpty else { return }
        let aggregate = Self.aggregate(minuteBuffer, timestamp: minuteStart)
        try insert(aggregate, into: "samples_minute")
        minuteBuffer.removeAll()
    }

    /// Rolls up `samples_minute` rows into `samples_hour` once an hour
    /// boundary has been crossed, and `samples_hour` into `samples_day` once
    /// a day boundary has been crossed. Uses `INSERT ... SELECT ... GROUP BY`
    /// per the plan, keyed by `ts / bucketSeconds` truncation.
    private func rollupHourAndDayIfNeeded(now: Date) throws {
        try exec("""
            INSERT OR REPLACE INTO samples_hour
            SELECT (ts / 3600) * 3600 AS bucket,
                   AVG(avg_cpu), MAX(max_cpu), AVG(avg_mem), MAX(max_mem),
                   SUM(request_count), SUM(client_error_count), SUM(server_error_count),
                   SUM(bytes_in), SUM(bytes_out), AVG(avg_latency_ms), MAX(p95_latency_ms),
                   MAX(max_thermal_state), MIN(min_battery_level), MAX(max_active_connections)
            FROM samples_minute
            WHERE (ts / 3600) * 3600 < (CAST(\(now.timeIntervalSince1970) AS INTEGER) / 3600) * 3600
            GROUP BY bucket;
            """)
        try exec("""
            INSERT OR REPLACE INTO samples_day
            SELECT (ts / 86400) * 86400 AS bucket,
                   AVG(avg_cpu), MAX(max_cpu), AVG(avg_mem), MAX(max_mem),
                   SUM(request_count), SUM(client_error_count), SUM(server_error_count),
                   SUM(bytes_in), SUM(bytes_out), AVG(avg_latency_ms), MAX(p95_latency_ms),
                   MAX(max_thermal_state), MIN(min_battery_level), MAX(max_active_connections)
            FROM samples_hour
            WHERE (ts / 86400) * 86400 < (CAST(\(now.timeIntervalSince1970) AS INTEGER) / 86400) * 86400
            GROUP BY bucket;
            """)
    }

    private func pruneExpired(now: Date) throws {
        let nowEpoch = now.timeIntervalSince1970
        try exec("DELETE FROM samples_minute WHERE ts < \(Int(nowEpoch - configuration.minuteRetentionSeconds));")
        try exec("DELETE FROM samples_hour WHERE ts < \(Int(nowEpoch - configuration.hourRetentionSeconds));")
        try exec("DELETE FROM samples_day WHERE ts < \(Int(nowEpoch - configuration.dayRetentionSeconds));")
        try exec("PRAGMA incremental_vacuum;")
    }

    // MARK: - Read

    public enum HistoryWindow: Sendable {
        case last24Hours, last7Days, last30Days

        var table: String {
            switch self {
            case .last24Hours: "samples_minute"
            case .last7Days: "samples_hour"
            case .last30Days: "samples_day"
            }
        }
    }

    /// Reads a window's rows, ordered oldest first. A timestamp with no row
    /// (app suspended) is simply absent — the plan draws that as a gap, not
    /// a zero, so callers must not fill missing minutes themselves.
    public func rows(for window: HistoryWindow) throws -> [MetricsHistoryRow] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT * FROM \(window.table) ORDER BY ts ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MetricsHistoryError.queryFailed(lastErrorMessage())
        }
        var rows: [MetricsHistoryRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Self.row(from: statement))
        }
        return rows
    }

    // MARK: - Helpers

    private static func flooredToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private static func aggregate(_ samples: [MetricsHistoryRow], timestamp: Date) -> MetricsHistoryRow {
        MetricsHistoryRow(
            timestamp: timestamp,
            averageCPUPercent: samples.map(\.averageCPUPercent).reduce(0, +) / Double(samples.count),
            maxCPUPercent: samples.map(\.maxCPUPercent).max() ?? 0,
            averageMemoryBytes: UInt64(samples.map { Double($0.averageMemoryBytes) }.reduce(0, +) / Double(samples.count)),
            maxMemoryBytes: samples.map(\.maxMemoryBytes).max() ?? 0,
            requestCount: samples.map(\.requestCount).reduce(0, +),
            clientErrorCount: samples.map(\.clientErrorCount).reduce(0, +),
            serverErrorCount: samples.map(\.serverErrorCount).reduce(0, +),
            bytesIn: samples.map(\.bytesIn).reduce(0, +),
            bytesOut: samples.map(\.bytesOut).reduce(0, +),
            averageLatencyMilliseconds: samples.map(\.averageLatencyMilliseconds).reduce(0, +) / Double(samples.count),
            p95LatencyMilliseconds: samples.map(\.p95LatencyMilliseconds).max() ?? 0,
            maxThermalStateRawValue: samples.map(\.maxThermalStateRawValue).max() ?? 0,
            minBatteryLevel: samples.map(\.minBatteryLevel).min() ?? 0,
            maxActiveConnections: samples.map(\.maxActiveConnections).max() ?? 0
        )
    }

    private func insert(_ row: MetricsHistoryRow, into table: String) throws {
        let sql = """
            INSERT OR REPLACE INTO \(table)
            (ts, avg_cpu, max_cpu, avg_mem, max_mem, request_count, client_error_count, server_error_count,
             bytes_in, bytes_out, avg_latency_ms, p95_latency_ms, max_thermal_state, min_battery_level, max_active_connections)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MetricsHistoryError.queryFailed(lastErrorMessage())
        }
        sqlite3_bind_int64(statement, 1, Int64(row.timestamp.timeIntervalSince1970))
        sqlite3_bind_double(statement, 2, row.averageCPUPercent)
        sqlite3_bind_double(statement, 3, row.maxCPUPercent)
        sqlite3_bind_int64(statement, 4, Int64(row.averageMemoryBytes))
        sqlite3_bind_int64(statement, 5, Int64(row.maxMemoryBytes))
        sqlite3_bind_int64(statement, 6, Int64(row.requestCount))
        sqlite3_bind_int64(statement, 7, Int64(row.clientErrorCount))
        sqlite3_bind_int64(statement, 8, Int64(row.serverErrorCount))
        sqlite3_bind_int64(statement, 9, Int64(row.bytesIn))
        sqlite3_bind_int64(statement, 10, Int64(row.bytesOut))
        sqlite3_bind_double(statement, 11, row.averageLatencyMilliseconds)
        sqlite3_bind_double(statement, 12, row.p95LatencyMilliseconds)
        sqlite3_bind_int64(statement, 13, Int64(row.maxThermalStateRawValue))
        sqlite3_bind_double(statement, 14, Double(row.minBatteryLevel))
        sqlite3_bind_int64(statement, 15, Int64(row.maxActiveConnections))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MetricsHistoryError.queryFailed(lastErrorMessage())
        }
    }

    private static func row(from statement: OpaquePointer?) -> MetricsHistoryRow {
        MetricsHistoryRow(
            timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
            averageCPUPercent: sqlite3_column_double(statement, 1),
            maxCPUPercent: sqlite3_column_double(statement, 2),
            averageMemoryBytes: UInt64(sqlite3_column_int64(statement, 3)),
            maxMemoryBytes: UInt64(sqlite3_column_int64(statement, 4)),
            requestCount: Int(sqlite3_column_int64(statement, 5)),
            clientErrorCount: Int(sqlite3_column_int64(statement, 6)),
            serverErrorCount: Int(sqlite3_column_int64(statement, 7)),
            bytesIn: Int(sqlite3_column_int64(statement, 8)),
            bytesOut: Int(sqlite3_column_int64(statement, 9)),
            averageLatencyMilliseconds: sqlite3_column_double(statement, 10),
            p95LatencyMilliseconds: sqlite3_column_double(statement, 11),
            maxThermalStateRawValue: Int(sqlite3_column_int64(statement, 12)),
            minBatteryLevel: Float(sqlite3_column_double(statement, 13)),
            maxActiveConnections: Int(sqlite3_column_int64(statement, 14))
        )
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MetricsHistoryError.queryFailed(lastErrorMessage())
        }
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

public enum MetricsHistoryError: Error, Sendable {
    case openFailed(String)
    case queryFailed(String)
}
