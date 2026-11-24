// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOConcurrencyHelpers
@testable import SwiftCoreWeb

/// A real server, a real WebSocket client: the upgrade, frames in both directions, and the engine surviving all of it.
final class WebSocketUpgradeTests: XCTestCase {
    private func startApp() async throws -> (app: WebApplication, port: Int) {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        app.mapWebSocket("/echo") { socket in
            for try await message in socket.messages() {
                switch message {
                case .text(let text): try await socket.send("echo: " + text)
                case .binary(let data): try await socket.send(data)
                }
            }
        }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await app.stopAsync() }
        return (app, port)
    }

    func testEchoOverARealWebSocketAndTheServerKeepsServing() async throws {
        let (_, port) = try await startApp()
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/echo")!)
        task.resume()

        try await task.send(.string("hello"))
        guard case .string(let first) = try await task.receive() else { return XCTFail("expected text") }
        XCTAssertEqual(first, "echo: hello")

        try await task.send(.data(Data([1, 2, 3])))
        guard case .data(let second) = try await task.receive() else { return XCTFail("expected binary") }
        XCTAssertEqual(second, Data([1, 2, 3]))

        task.sendPing { _ in }
        task.cancel(with: .normalClosure, reason: nil)

        // The engine is still alive and serves plain HTTP after a WebSocket came and went.
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/ping")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
    }

    func testUnknownWebSocketPathIsRefusedWithoutHarmingTheServer() async throws {
        let (_, port) = try await startApp()
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/nope")!)
        task.resume()
        do { _ = try await task.receive(); XCTFail("must not connect") } catch {}
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/ping")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")
    }
}

/// A network change closes and re-opens the listeners; the engine must keep running and keep serving through it.
final class NetworkRebindTests: XCTestCase {
    func testRebindKeepsTheServerRunningAndServing() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        builder.useHost("0.0.0.0")
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        let runReturned = NIOLockedValueBox(false)
        Task {
            try? await app.runAsync()
            runReturned.withLockedValue { $0 = true }
        }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await app.stopAsync() }
        let engine = try XCTUnwrap(app.engineBox.engine)

        await engine.rebindOnNetworkChange()
        await engine.rebindOnNetworkChange()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(runReturned.withLockedValue { $0 }, "runAsync must not return because listeners were rebound")
        XCTAssertTrue(app.isRunning)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:\(port)/ping")!)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pong")

        try await app.stopAsync()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(runReturned.withLockedValue { $0 }, "stopAsync ends runAsync")
    }
}
