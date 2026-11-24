// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A TCP allocation on a TURN server (RFC 8656 with the TCP extension of RFC 6062), seen from the host that owns it.
///
/// The server opens a public address (`relayed`). A device that connects to it is announced as an `Attempt`; `accept` then
/// opens a second connection to the server and binds it to that device, which gives a byte pipe to the device. What travels
/// over it is the tunnel's SSH, already encrypted: the relay moves bytes it cannot read.
final class TURNAllocation: Sendable {
    struct Credentials: Sendable {
        let username: String
        let password: String
    }

    /// A device connected to the relayed address and waits to be bound.
    struct Attempt: Sendable {
        let connectionID: [UInt8]
        let peerHost: String
        let peerPort: Int

        init(connectionID: [UInt8], peer: (host: String, port: Int)) {
            self.connectionID = connectionID
            peerHost = peer.host
            peerPort = peer.port
        }
    }

    enum Failure: Error, Equatable {
        case timedOut
        case closed
        case refused(code: Int)
        case unexpectedResponse
    }

    private struct Authentication {
        var realm: String
        var nonce: String
        let key: [UInt8]
    }

    /// The public address devices connect to.
    let relayedHost: String
    let relayedPort: Int
    /// Devices that connected to the relayed address; ends when the allocation does.
    var attempts: AsyncStream<Attempt> { control.attempts }

    private let serverHost: String
    private let serverPort: Int
    private let credentials: Credentials
    private let control: TURNControlConnection
    private let group: EventLoopGroup
    private let requestTimeout: TimeAmount
    private let authentication: NIOLockedValueBox<Authentication>
    private let permitted = NIOLockedValueBox<[String]>([])
    private static let maxPermitted = 64
    private let sessions = NIOLockedValueBox<(closed: Bool, channels: [ObjectIdentifier: Channel])>((false, [:]))
    private let refresher = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private static let transport = STUNMessage.Attribute(type: STUNMessage.AttributeType.requestedTransport, value: [6, 0, 0, 0]) // TCP

    private init(
        serverHost: String, serverPort: Int, credentials: Credentials, control: TURNControlConnection, group: EventLoopGroup,
        authentication: Authentication, relayedHost: String, relayedPort: Int, requestTimeout: TimeAmount
    ) {
        self.requestTimeout = requestTimeout
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.credentials = credentials
        self.control = control
        self.group = group
        self.authentication = NIOLockedValueBox(authentication)
        self.relayedHost = relayedHost
        self.relayedPort = relayedPort
    }

    // MARK: - Allocate

    /// Connects to the TURN server, authenticates (long-term credentials) and asks for a TCP allocation. The allocation
    /// and its permissions are renewed every `refreshEvery` (the server grants 10 minutes and 5 minutes).
    static func allocate(
        server host: String, port: Int, credentials: Credentials,
        refreshEvery: TimeAmount = .seconds(120),
        requestTimeout: TimeAmount = .seconds(5),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> TURNAllocation {
        let control = try await TURNControlConnection.connect(host: host, port: port, group: group)
        do {
            // First request without credentials: the server answers 401 with the realm and nonce to use.
            let probe = try await control.send(
                STUNRequest(message: STUNMessage(method: STUNMessage.Method.allocate, messageClass: .request, attributes: [transport]), key: nil),
                timeout: requestTimeout
            )
            guard probe.messageClass == .error, probe.errorCode?.code == 401,
                  let realm = probe.attribute(STUNMessage.AttributeType.realm), let nonce = probe.attribute(STUNMessage.AttributeType.nonce) else {
                throw probe.errorCode.map { Failure.refused(code: $0.code) } ?? Failure.unexpectedResponse
            }
            var authentication = Authentication(
                realm: String(decoding: realm, as: UTF8.self), nonce: String(decoding: nonce, as: UTF8.self),
                key: Array(Insecure.MD5.hash(data: Data("\(credentials.username):\(String(decoding: realm, as: UTF8.self)):\(credentials.password)".utf8)))
            )
            var response = try await control.send(
                signed(STUNMessage(method: STUNMessage.Method.allocate, messageClass: .request, attributes: [transport]), credentials, authentication),
                timeout: requestTimeout
            )
            if response.errorCode?.code == 438, let fresh = response.attribute(STUNMessage.AttributeType.nonce) { // stale nonce: once more
                authentication.nonce = String(decoding: fresh, as: UTF8.self)
                response = try await control.send(
                    signed(STUNMessage(method: STUNMessage.Method.allocate, messageClass: .request, attributes: [transport]), credentials, authentication),
                    timeout: requestTimeout
                )
            }
            guard response.messageClass == .success else { throw Failure.refused(code: response.errorCode?.code ?? 0) }
            guard let relayed = response.attribute(STUNMessage.AttributeType.xorRelayedAddress)
                .flatMap({ STUNMessage.decodeXorAddress($0, transactionID: response.transactionID) }) else { throw Failure.unexpectedResponse }

            let allocation = TURNAllocation(
                serverHost: host, serverPort: port, credentials: credentials, control: control, group: group,
                authentication: authentication, relayedHost: relayed.host, relayedPort: relayed.port, requestTimeout: requestTimeout
            )
            let lifetime = response.attribute(STUNMessage.AttributeType.lifetime).map { STUNMessage.readUInt32($0, 0) } ?? 600
            allocation.startRefreshing(every: min(refreshEvery, .seconds(max(Int64(lifetime) / 2, 5))), lifetime: lifetime)
            return allocation
        } catch {
            await control.close()
            throw error
        }
    }

    // MARK: - Permissions and connections

    /// Lets `ip` connect to the relayed address (the server drops everyone else). Renewed automatically.
    func permit(ip rawIP: String) async throws {
        let ip = rawIP.hasPrefix("::ffff:") ? String(rawIP.dropFirst(7)) : rawIP // an IPv4 client seen on a dual-stack socket
        try await createPermissions([ip]) // throws for anything but an IPv4 address, which is then not remembered
        permitted.withLockedValue { list in
            list.removeAll { $0 == ip }
            list.append(ip)
            if list.count > Self.maxPermitted { list.removeFirst(list.count - Self.maxPermitted) }
        }
    }

    /// Opens the data connection for `attempt`, binds it to that device and hands the bound channel to `setUp`, which installs
    /// the handlers that will speak over it, before any byte is delivered. The channel is closed if anything fails.
    func accept(_ attempt: Attempt, setUp: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws {
        let binder = TURNBindHandler()
        let binderBox = UncheckedSendableBox(binder)
        let channel = try await ClientBootstrap(group: group.next())
            .channelInitializer { channel in TCPKeepAlive.apply(to: channel).flatMapThrowing { try channel.pipeline.syncOperations.addHandler(binderBox.value) } }
            .connect(host: serverHost, port: serverPort).get()
        do {
            let request = Self.signed(
                STUNMessage(method: STUNMessage.Method.connectionBind, messageClass: .request, attributes: [
                    .init(type: STUNMessage.AttributeType.connectionID, value: attempt.connectionID),
                ]),
                credentials, authentication.withLockedValue { $0 }
            )
            let response = try await binder.send(request, on: channel, timeout: requestTimeout)
            guard response.messageClass == .success else { throw Failure.refused(code: response.errorCode?.code ?? 0) }
            try await channel.eventLoop.flatSubmit { setUp(channel) }.get() // pipeline changes belong on the channel's own loop
            let id = ObjectIdentifier(channel)
            let registered = sessions.withLockedValue { state -> Bool in
                if state.closed { return false }
                state.channels[id] = channel
                return true
            }
            guard registered else { throw Failure.closed }
            channel.closeFuture.whenComplete { [weak self] _ in self?.sessions.withLockedValue { _ = $0.channels.removeValue(forKey: id) } }
            binder.activate(on: channel)
        } catch {
            try? await channel.close()
            throw error
        }
    }

    func close() async {
        refresher.withLockedValue { $0.take() }?.cancel()
        let open = sessions.withLockedValue { state -> [Channel] in
            state.closed = true
            defer { state.channels = [:] }
            return Array(state.channels.values)
        }
        for channel in open { try? await channel.close() } // sessions that came over this allocation end with it
        if control.channel.isActive {
            // Lifetime 0 frees the allocation at once; best effort.
            _ = try? await authenticated(method: STUNMessage.Method.refresh, attributes: [.init(type: STUNMessage.AttributeType.lifetime, value: STUNMessage.bytes(of: UInt32(0)))])
        }
        await control.close()
    }

    // MARK: - Requests

    private func createPermissions(_ ips: [String]) async throws {
        let id = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let attributes = ips.compactMap { STUNMessage.xorAddressAttribute(host: $0, port: 0, transactionID: id, type: STUNMessage.AttributeType.xorPeerAddress) }
        guard attributes.count == ips.count else { throw Failure.unexpectedResponse }
        _ = try await authenticated(method: STUNMessage.Method.createPermission, attributes: attributes, transactionID: id)
    }

    private func startRefreshing(every interval: TimeAmount, lifetime: UInt32) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval.nanoseconds))
                guard !Task.isCancelled, let self else { return }
                do {
                    _ = try await self.authenticated(method: STUNMessage.Method.refresh, attributes: [.init(type: STUNMessage.AttributeType.lifetime, value: STUNMessage.bytes(of: lifetime))])
                    let ips = Array(self.permitted.withLockedValue { $0 })
                    if !ips.isEmpty { try await self.createPermissions(ips) }
                } catch {
                    await self.control.close() // the allocation is gone or unreachable: `attempts` ends
                    return
                }
            }
        }
        refresher.withLockedValue { $0 = task }
    }

    /// An authenticated request on the control connection; the nonce is renewed once when the server calls it stale (438).
    private func authenticated(method: UInt16, attributes: [STUNMessage.Attribute], transactionID: [UInt8]? = nil) async throws -> STUNMessage {
        for attempt in 0..<2 {
            let message = STUNMessage(method: method, messageClass: .request, transactionID: attempt == 0 ? transactionID : nil, attributes: attributes)
            let response = try await control.send(Self.signed(message, credentials, authentication.withLockedValue { $0 }), timeout: requestTimeout)
            if response.messageClass == .success { return response }
            if attempt == 0, response.errorCode?.code == 438, let nonce = response.attribute(STUNMessage.AttributeType.nonce) {
                authentication.withLockedValue { $0.nonce = String(decoding: nonce, as: UTF8.self) }
                continue
            }
            throw Failure.refused(code: response.errorCode?.code ?? 0)
        }
        throw Failure.unexpectedResponse
    }

    private static func signed(_ message: STUNMessage, _ credentials: Credentials, _ authentication: Authentication) -> STUNRequest {
        var signed = message
        signed.attributes += [
            .init(type: STUNMessage.AttributeType.username, value: Array(credentials.username.utf8)),
            .init(type: STUNMessage.AttributeType.realm, value: Array(authentication.realm.utf8)),
            .init(type: STUNMessage.AttributeType.nonce, value: Array(authentication.nonce.utf8)),
        ]
        return STUNRequest(message: signed, key: authentication.key, verifying: true)
    }
}

extension STUNRequest {
    /// `key` adds MESSAGE-INTEGRITY (long-term credentials); `nil` sends the message as it is.
    init(message: STUNMessage, key: [UInt8]?, verifying: Bool = false) {
        self.init(transactionID: message.transactionID, bytes: message.encoded(integrityKey: key), integrityKey: verifying ? key : nil)
    }
}
