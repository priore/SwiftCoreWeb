// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import UIKit

/// One 1 Hz sample of device health, built entirely from public iOS APIs
/// (see `AI-Workspace/Plans/DEVICE_DASHBOARD_PLAN.md`'s metrics catalog for
/// what iOS deliberately does *not* expose — never simulated here).
public struct DeviceSnapshot: Sendable {
    public let timestamp: Date
    public let modelIdentifier: String
    public let deviceName: String
    public let systemVersion: String
    public let cpuUsagePercent: Double
    public let processThreadCount: Int
    public let appMemoryFootprintBytes: UInt64
    public let availableMemoryBytes: UInt64
    public let physicalMemoryBytes: UInt64
    public let thermalState: ProcessInfo.ThermalState
    public let batteryLevel: Float
    public let batteryState: UIDevice.BatteryState
    public let isLowPowerModeEnabled: Bool
    public let freeStorageBytes: Int64
    public let totalStorageBytes: Int64
    public let systemUptimeSeconds: TimeInterval
}

/// Samples device health once per second on a background `Task` loop
/// (`Task.sleep`, not `DispatchQueue`, per the project's concurrency style).
/// `UIDevice`/`ProcessInfo.thermalState` reads are `@MainActor`-isolated on
/// current SDKs, so this type is itself `@MainActor`: the dashboard model
/// reads `latest` and observes `onSample` from the main actor too, so no
/// hop is needed at the call site.
@MainActor
public final class DeviceSampler {
    /// Called on every sample, on the main actor.
    public var onSample: (@MainActor (DeviceSnapshot) -> Void)?

    public private(set) var latest: DeviceSnapshot?

    private var loopTask: Task<Void, Never>?
    private var previousCPUTicks: host_cpu_load_info?

    public init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    deinit {
        loopTask?.cancel()
    }

    /// Starts the 1 Hz sampling loop. Calling this again while already
    /// running restarts the loop (matches the dashboard's own start/stop).
    public func start() {
        stop()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.sample()
                self.latest = snapshot
                self.onSample?(snapshot)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func sample() -> DeviceSnapshot {
        let storage = Self.storageCapacities()
        return DeviceSnapshot(
            timestamp: Date(),
            modelIdentifier: Self.modelIdentifier(),
            deviceName: UIDevice.current.name,
            systemVersion: UIDevice.current.systemVersion,
            cpuUsagePercent: totalCPUUsagePercent(),
            processThreadCount: Self.processThreadCount(),
            appMemoryFootprintBytes: Self.appMemoryFootprintBytes(),
            availableMemoryBytes: UInt64(os_proc_available_memory()),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            thermalState: ProcessInfo.processInfo.thermalState,
            batteryLevel: UIDevice.current.batteryLevel,
            batteryState: UIDevice.current.batteryState,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            freeStorageBytes: storage.free,
            totalStorageBytes: storage.total,
            systemUptimeSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Total system CPU usage as a delta of `host_processor_info` ticks
    /// against the previous sample (a single instantaneous reading isn't
    /// meaningful — CPU % is defined over an interval). First call after
    /// `start()` has no previous ticks to diff against, so it returns 0.
    private func totalCPUUsagePercent() -> Double {
        guard let ticks = Self.hostCPUTicks() else { return 0 }
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks else { return 0 }

        let userDelta = Double(ticks.cpu_ticks.0 &- previous.cpu_ticks.0)
        let systemDelta = Double(ticks.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idleDelta = Double(ticks.cpu_ticks.2 &- previous.cpu_ticks.2)
        let niceDelta = Double(ticks.cpu_ticks.3 &- previous.cpu_ticks.3)
        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard totalDelta > 0 else { return 0 }
        return ((userDelta + systemDelta + niceDelta) / totalDelta) * 100
    }

    private static func hostCPUTicks() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// The running process's thread count, via `task_threads` (freed
    /// immediately after counting — this only needs the count, not the
    /// thread ports themselves).
    private static func processThreadCount() -> Int {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))
        return Int(threadCount)
    }

    /// The app's resident memory footprint, via `task_vm_info.phys_footprint`
    /// — the same figure Xcode's memory gauge and the OS's jetsam use, more
    /// representative than raw resident size for iOS's memory pressure model.
    private static func appMemoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// `uname().machine` (e.g. `"iPhone15,2"`), the raw hardware identifier
    /// — not the marketing name, which has no public API on iOS.
    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func storageCapacities() -> (free: Int64, total: Int64) {
        guard let url = URL.documentsDirectoryOrNil,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        else { return (0, 0) }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        return (free, total)
    }
}

private extension URL {
    static var documentsDirectoryOrNil: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}
