// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers
import os

private let remoteLogger = Logger(subsystem: "SwiftCoreWebP2P", category: "remote")

/// Keeps the host reachable from other networks while the tunnel runs: holds a TURN allocation, publishes its address to the
/// rendezvous, lets in the devices that knock, and serves SSH on each connection the relay hands over. When the allocation
/// is lost it asks for a new one.
final class RemoteAccessPublisher: Sendable {
    private let remote: P2PRemoteAccess
    private let pairing: PairingManager
    private let server: SSHTunnelServer
    private let publishEvery: TimeInterval
    private let pollEvery: TimeInterval
    private let task = NIOLockedValueBox<Task<Void, Never>?>(nil)

    init(remote: P2PRemoteAccess, pairing: PairingManager, server: SSHTunnelServer, publishEvery: TimeInterval = 60, pollEvery: TimeInterval = 2) {
        self.remote = remote
        self.pairing = pairing
        self.server = server
        self.publishEvery = publishEvery
        self.pollEvery = pollEvery
    }

    func start() {
        let task = Task { [self] in
            var retry: TimeInterval = 2
            while !Task.isCancelled {
                do {
                    let issued = remote.relay.credentials()
                    let allocation = try await TURNAllocation.allocate(
                        server: remote.relay.host, port: remote.relay.port, credentials: .init(username: issued.username, password: issued.password)
                    )
                    retry = 2
                    await serve(allocation)
                    await allocation.close()
                } catch {
                    remoteLogger.error("Relay unavailable: \(String(describing: error), privacy: .public)")
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(retry * 1_000_000_000))
                retry = min(retry * 2, 60)
            }
        }
        self.task.withLockedValue { $0 = task }
    }

    func stop() async {
        let task = self.task.withLockedValue { $0.take() }
        task?.cancel()
        await task?.value
    }

    /// Returns when the allocation is lost (or the task is cancelled).
    private func serve(_ allocation: TURNAllocation) async {
        let client = RendezvousClient(baseURL: remote.rendezvous)
        let server = server
        let pending = NIOLockedValueBox(0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await attempt in allocation.attempts {
                    // Each attempt costs a connection to the relay; past the limit, further ones are dropped until some finish.
                    guard pending.withLockedValue({ count -> Bool in count < 32 ? { count += 1; return true }() : false }) else { continue }
                    Task {
                        defer { pending.withLockedValue { $0 -= 1 } }
                        try? await allocation.accept(attempt) { server.serve($0) }
                    }
                }
            }
            group.addTask { [self] in
                var untilPublish: TimeInterval = 0
                while !Task.isCancelled {
                    if untilPublish <= 0 {
                        do {
                            try await client.publish(
                                [.init(kind: "relay", host: allocation.relayedHost, port: allocation.relayedPort)],
                                hostKey: pairing.hostSigningKey, hostFingerprint: pairing.hostFingerprint
                            )
                        } catch { remoteLogger.error("Could not publish to the rendezvous: \(String(describing: error), privacy: .public)") }
                        untilPublish = publishEvery
                    }
                    if let knocks = try? await client.collectKnocks(hostKey: pairing.hostSigningKey, hostFingerprint: pairing.hostFingerprint) {
                        for knock in knocks where pairing.isPaired(deviceID: knock.deviceFingerprint) {
                            // Only paired devices are let through (the knock is verified against the device's own signature);
                            // the relay is asked for IPv4 addresses only, anything else is skipped.
                            try? await allocation.permit(ip: knock.address)
                        }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
                    untilPublish -= pollEvery
                }
            }
            // The first task ends when the allocation does; then stop the other.
            await group.next()
            group.cancelAll()
        }
    }
}
