// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Testing
import Foundation
import NIOConcurrencyHelpers
@testable import SwiftCoreWeb

private final class RecordingExtension: ServerExtension, Sendable {
    private let state = NIOLockedValueBox<(ingress: RequestIngress?, stops: Int)>((nil, 0))
    var ingress: RequestIngress? { state.withLockedValue { $0.ingress } }
    var stops: Int { state.withLockedValue { $0.stops } }
    func start(ingress: RequestIngress) async throws { state.withLockedValue { $0.ingress = ingress } }
    func stop() async { state.withLockedValue { $0.stops += 1 } }
}

@Suite(.serialized)
struct RequestIngressTests {
    @Test func extensionGetsTheSameRoutesLimitsAndLifecycle() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port).maxConcurrentConnections(1).rateLimit { $0.capacity = 1; $0.refillPerSecond = 0.001 }
        let recorder = RecordingExtension()
        builder.addExtension(recorder)
        let app = builder.build()
        app.useAuthorization()
        app.mapGet("/ping") { _ in "pong" }
        app.mapWebSocket("/live", auth: .authenticated) { _ in }

        let server = Task { try await app.runAsync() }
        defer { server.cancel(); Task { try? await app.stopAsync() } }
        var ingress: RequestIngress?
        for _ in 0..<100 {
            ingress = recorder.ingress
            if ingress != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let ingressValue = try #require(ingress)

        let response = await ingressValue.dispatch(HttpRequest(method: .get, path: "/ping"))
        #expect(response.status.rawValue == 200)
        #expect(await ingressValue.openConnection())
        #expect(await !ingressValue.openConnection()) // gate shared with the HTTP engine: cap is 1
        await ingressValue.closeConnection()
        #expect(await ingressValue.allowRequest(from: "peer"))
        #expect(await !ingressValue.allowRequest(from: "peer")) // capacity 1, no refill: second is limited
        #expect(await ingressValue.allowRequest(from: "127.0.0.1")) // namespaced: not the loopback exemption, own bucket

        let denied = await ingressValue.acceptWebSocket(HttpRequest(method: .get, path: "/live"), transport: .init(messages: { AsyncThrowingStream { $0.finish() } }, send: { _ in }, close: { _ in }))
        #expect(denied?.status.rawValue == 401)

        let missing = await ingressValue.acceptWebSocket(HttpRequest(method: .get, path: "/nope"), transport: .init(messages: { AsyncThrowingStream { $0.finish() } }, send: { _ in }, close: { _ in }))
        #expect(missing?.status.rawValue == 404)

        try await app.stopAsync()
        #expect(recorder.stops == 1)
    }

    @Test func failingExtensionStartFailsRunAndLeavesNothingRunning() async throws {
        struct Boom: Error {}
        final class Failing: ServerExtension, Sendable {
            func start(ingress: RequestIngress) async throws { throw Boom() }
            func stop() async {}
        }
        let builder = WebApplication.createBuilder()
        builder.usePort(Int.random(in: 30_000..<60_000)).addExtension(Failing())
        let app = builder.build()
        await #expect(throws: Boom.self) { try await app.runAsync() }
        #expect(!app.isRunning)
    }
}
