// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import Network
import os

private let watchdogLogger = Logger(subsystem: "SwiftCoreWeb", category: "server")

/// Watches for interface/IP changes via `NWPathMonitor` and asks the server
/// engine to rebind on each change, per the concurrency/lifecycle/network watchdog design. Runs on its own dispatch queue;
/// the rebind callback hops back onto the engine's actor.
final class NetworkWatchdog: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "SwiftCoreWeb.NetworkWatchdog")
    private var lastInterfaceNames: Set<String> = []
    private let onChange: @Sendable () async -> Void

    init(onChange: @escaping @Sendable () async -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let names = Set(path.availableInterfaces.map(\.name))
            guard names != self.lastInterfaceNames else { return }
            self.lastInterfaceNames = names
            watchdogLogger.info("Network path changed (interfaces: \(names.sorted().joined(separator: ", "), privacy: .public)) — rebinding listeners")
            let callback = self.onChange
            Task { await callback() }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
