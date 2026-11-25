// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import XCTest
import NIOConcurrencyHelpers
import SwiftCoreWeb
@testable import SwiftCoreWebP2P

/// Path changes, timeouts and retries: how the connection behaves when the network is not steady.
final class NetworkResilienceTests: XCTestCase {
    // MARK: - Path tracking

    func testTheTrackerTellsLossRestorationAndReroutingApart() {
        var tracker = NetworkPathTracker()
        let wifi = NetworkPath(isSatisfied: true, interfaces: ["wifi"])
        let cellular = NetworkPath(isSatisfied: true, interfaces: ["cellular"])
        let none = NetworkPath(isSatisfied: false, interfaces: [])
        XCTAssertEqual(tracker.observe(wifi), .none, "the first path is only a starting point")
        XCTAssertEqual(tracker.observe(wifi), .none)
        XCTAssertEqual(tracker.observe(cellular), .rerouted)
        XCTAssertEqual(tracker.observe(none), .lost)
        XCTAssertEqual(tracker.observe(none), .none)
        XCTAssertEqual(tracker.observe(wifi), .restored)
        XCTAssertEqual(tracker.observe(NetworkPath(isSatisfied: true, interfaces: ["wifi", "cellular"])), .rerouted)
        var offline = NetworkPathTracker()
        XCTAssertEqual(offline.observe(none), .lost, "starting without a network")
    }

    private final class ControlledPaths: NetworkPathSource, @unchecked Sendable {
        private let continuation = NIOLockedValueBox<AsyncStream<NetworkPath>.Continuation?>(nil)
        func updates() -> AsyncStream<NetworkPath> {
            AsyncStream { continuation in self.continuation.withLockedValue { $0 = continuation } }
        }
        func send(_ path: NetworkPath) { _ = continuation.withLockedValue { $0 }?.yield(path) }
    }

    private func startedHost() async throws -> (host: P2PHost, peer: SCWPeerConnection, base: URL, paths: ControlledPaths) {
        let builder = WebApplication.createBuilder()
        builder.usePort(Int.random(in: 30_000..<60_000))
        let host = try builder.useP2P(storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/open") { _ in "open" }
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let payload = try XCTUnwrap(host.openPairing(host: "127.0.0.1"))
        let peer = try await SCWPeerConnection.pair(payload, storage: InMemoryTunnelStorage())
        let paths = ControlledPaths()
        peer.pathSource.withLockedValue { $0 = paths }
        let base = try await peer.start()
        try await Task.sleep(nanoseconds: 300_000_000) // the watcher has subscribed
        return (host, peer, base, paths)
    }

    private func status(_ url: URL) async -> Int {
        ((try? await URLSession(configuration: .ephemeral).data(from: url))?.1 as? HTTPURLResponse)?.statusCode ?? -1
    }

    func testAChangeOfInterfaceReconnectsWithoutWaitingForTheKeepalive() async throws {
        let (_, peer, base, paths) = try await startedHost()
        let before = await status(base.appendingPathComponent("open"))
        XCTAssertEqual(before, 200)
        paths.send(NetworkPath(isSatisfied: true, interfaces: ["wifi"]))
        paths.send(NetworkPath(isSatisfied: true, interfaces: ["cellular"])) // the connection in use is dropped at once
        var recovered = false
        for _ in 0..<40 where !recovered { // far less than the keepalive's minute
            try await Task.sleep(nanoseconds: 250_000_000)
            recovered = await status(base.appendingPathComponent("open")) == 200
        }
        XCTAssertTrue(recovered)
        await peer.stop()
    }

    func testNothingIsTriedWithoutANetworkAndItResumesWhenItReturns() async throws {
        let (host, peer, base, paths) = try await startedHost()
        paths.send(NetworkPath(isSatisfied: true, interfaces: ["wifi"]))
        paths.send(NetworkPath(isSatisfied: false, interfaces: []))
        try await Task.sleep(nanoseconds: 200_000_000)
        await peer.dropConnection() // the connection dies, as it would without a network
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let whileOffline = await status(base.appendingPathComponent("open"))
        XCTAssertNotEqual(whileOffline, 200, "no reconnection while the system says there is no network")
        XCTAssertEqual(host.pairing?.devices.count, 1)

        paths.send(NetworkPath(isSatisfied: true, interfaces: ["wifi"]))
        var recovered = false
        for _ in 0..<40 where !recovered {
            try await Task.sleep(nanoseconds: 250_000_000)
            recovered = await status(base.appendingPathComponent("open")) == 200
        }
        XCTAssertTrue(recovered, "back online, the connection returns at once")
        await peer.stop()
    }

    // MARK: - Timeouts

    func testTimeoutsAreWiderAcrossTheInternetThanOnTheLocalNetwork() {
        let timeouts = P2PTimeouts.default
        XCTAssertLessThan(timeouts.localConnect, timeouts.wideAreaConnect)
        XCTAssertLessThan(timeouts.localHandshake, timeouts.wideAreaHandshake)
        var custom = P2PTimeouts()
        custom.wideAreaConnect = 20
        XCTAssertEqual(custom.wideAreaConnectAmount.nanoseconds, 20_000_000_000)
    }

    // MARK: - Retries

    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var responses: [Int] = []
        nonisolated(unsafe) static var requests = 0
        private static let lock = NSLock()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            Self.requests += 1
            let status = Self.responses.isEmpty ? 204 : Self.responses.removeFirst()
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func reset(_ statuses: [Int]) { lock.lock(); responses = statuses; requests = 0; lock.unlock() }
        static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    }

    private func client() -> RendezvousClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return RendezvousClient(baseURL: URL(string: "http://rendezvous.invalid")!, session: URLSession(configuration: configuration), retryDelays: [0.01, 0.01])
    }

    func testIdempotentCallsAreRetriedOnTransientFailures() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let fingerprint = "SHA256:" + String(repeating: "A", count: 43)
        Stub.reset([503, 429])
        try await client().publish([], hostKey: key, hostFingerprint: fingerprint)
        XCTAssertEqual(Stub.count, 3, "two transient failures, then success")
        Stub.reset([503, 503, 503, 503])
        do { try await client().knock(hostFingerprint: fingerprint, deviceKey: key); XCTFail("must give up") } catch {
            XCTAssertEqual(error as? RendezvousClient.Failure, .badResponse(status: 503))
        }
        XCTAssertEqual(Stub.count, 3, "the limit is three attempts")
    }

    func testRefusalsAndNonRepeatableCallsAreNotRetried() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let fingerprint = "SHA256:" + String(repeating: "A", count: 43)
        Stub.reset([400])
        do { try await client().publish([], hostKey: key, hostFingerprint: fingerprint); XCTFail() } catch {}
        XCTAssertEqual(Stub.count, 1, "a refusal would be refused again")
        Stub.reset([503, 204])
        do { _ = try await client().collectKnocks(hostKey: key, hostFingerprint: fingerprint); XCTFail("collecting empties the knocks: sent once") } catch {}
        XCTAssertEqual(Stub.count, 1)
        XCTAssertTrue(RendezvousClient.isTransient(URLError(.timedOut)))
        XCTAssertFalse(RendezvousClient.isTransient(URLError(.cancelled)))
        XCTAssertFalse(RendezvousClient.isTransient(RendezvousClient.Failure.untrustedRecord))
    }
}
