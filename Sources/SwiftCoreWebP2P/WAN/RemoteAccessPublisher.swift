// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
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
    /// Punches in progress by device, and the knocks already acted on, so a replayed knock or one device cannot hold every slot.
    private let punching = NIOLockedValueBox<(active: Set<String>, recent: [String: Date])>(([], [:]))
    private let punchTasks = NIOLockedValueBox<[UUID: Task<Void, Never>]>([:])
    private let mappedAddress = NIOLockedValueBox<RendezvousRecord.Candidate?>(nil)

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
        for punch in punchTasks.withLockedValue({ $0.values }) { punch.cancel() }
    }

    /// Opens a connection to a paired device from the tunnel's own port while the device connects to this one: through most
    /// NATs the two crossing attempts make a connection, which is then served like any other. Gives up after a few seconds.
    /// One punch per device at a time, at most four overall, and a knock already acted on is ignored for a minute.
    func punch(to candidate: RendezvousRecord.Candidate, from localPort: Int, device: String) {
        let key = device + "|" + candidate.host + ":" + String(candidate.port)
        let allowed = punching.withLockedValue { state -> Bool in
            state.recent = state.recent.filter { $0.value > Date() }
            guard state.active.count < 4, !state.active.contains(device), state.recent[key] == nil else { return false }
            state.active.insert(device)
            state.recent[key] = Date().addingTimeInterval(60)
            return true
        }
        guard allowed else { return }
        let server = server, punching = punching, tasks = punchTasks, id = UUID()
        let task = Task {
            defer {
                punching.withLockedValue { _ = $0.active.remove(device) }
                tasks.withLockedValue { _ = $0.removeValue(forKey: id) }
            }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, !Task.isCancelled {
                do {
                    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton.next())
                        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                        .channelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
                        .bind(to: SocketAddress(ipAddress: "0.0.0.0", port: localPort))
                        .connectTimeout(.seconds(2))
                        .connect(host: candidate.host, port: candidate.port).get()
                    do {
                        try await TCPKeepAlive.apply(to: channel).get()
                        try await channel.eventLoop.flatSubmit { server.serve(channel) }.get()
                    } catch { try? await channel.close() }
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        punchTasks.withLockedValue { $0[id] = task }
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
            // The host's public address as the TURN server sees the tunnel port; asked apart from the loop below because a
            // server that does not answer STUN over TCP would otherwise delay the knocks.
            group.addTask { [self] in
                while !Task.isCancelled {
                    var found: RendezvousRecord.Candidate?
                    if let port = server.port,
                       let mapped = try? await STUNClient.reflexiveAddress(server: remote.relay.host, port: remote.relay.port, localPort: port, timeout: .seconds(3)) {
                        found = .init(kind: "direct", host: mapped.host, port: mapped.port)
                    }
                    mappedAddress.withLockedValue { $0 = found } // a lookup that fails withdraws the address instead of keeping a stale one
                    try? await Task.sleep(nanoseconds: UInt64(publishEvery * 1_000_000_000))
                }
            }
            group.addTask { [self] in
                var untilPublish: TimeInterval = 0
                var publishedMapping: RendezvousRecord.Candidate?
                while !Task.isCancelled {
                    // Publishes on schedule, and again as soon as the public address becomes known or changes.
                    if untilPublish <= 0 || mappedAddress.withLockedValue({ $0 }) != publishedMapping {
                        do {
                            // The relay; the TURN server's own address, where a device learns its public address (STUN); and
                            // this host's, learned from the tunnel's own port so a device can aim a direct connection at it.
                            var candidates: [RendezvousRecord.Candidate] = [
                                .init(kind: "relay", host: allocation.relayedHost, port: allocation.relayedPort),
                                .init(kind: "stun", host: remote.relay.host, port: remote.relay.port),
                            ] + remote.stunServers.map { .init(kind: "stun", host: $0.host, port: $0.port) }
                            if let direct = mappedAddress.withLockedValue({ $0 }) { candidates.append(direct) }
                            publishedMapping = mappedAddress.withLockedValue { $0 }
                            try await client.publish(candidates, hostKey: pairing.hostSigningKey, hostFingerprint: pairing.hostFingerprint)
                        } catch { remoteLogger.error("Could not publish to the rendezvous: \(String(describing: error), privacy: .public)") }
                        untilPublish = publishEvery
                    }
                    if let knocks = try? await client.collectKnocks(hostKey: pairing.hostSigningKey, hostFingerprint: pairing.hostFingerprint) {
                        for knock in knocks where pairing.isPaired(deviceID: knock.deviceFingerprint) {
                            if let direct = knock.direct, let tunnelPort = server.port { punch(to: direct, from: tunnelPort, device: knock.deviceFingerprint) }
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
