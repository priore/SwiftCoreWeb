// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOCore
import NIOWebSocket
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

    func testLargeMessagePingAndServerInitiatedClose() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        app.mapWebSocket("/once") { socket in
            for try await message in socket.messages() {
                if case .text(let text) = message { try await socket.send("\(text.utf8.count)"); return } // returns: server closes
            }
        }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await app.stopAsync() }

        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/once")!)
        task.resume()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume() } // answered with a pong
        }
        try await task.send(.string(String(repeating: "a", count: 300_000))) // well above NIO's 16 KiB default frame size
        guard case .string(let size) = try await task.receive() else { return XCTFail("expected text") }
        XCTAssertEqual(size, "300000")
        // The handler returned: the server says goodbye with a close frame, the client sees a clean close.
        do { _ = try await task.receive(); XCTFail("the connection should be closed") } catch {}
        XCTAssertEqual(task.closeCode, .normalClosure)
    }

    func testHandlerThatFallsBehindGetsSlowConsumerAndTheConnectionCloses() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        let outcome = NIOLockedValueBox<String?>(nil)
        app.mapWebSocket("/slow") { socket in
            let stream = socket.messages()
            try await Task.sleep(nanoseconds: 1_500_000_000) // reads nothing while the client floods
            do { for try await _ in stream {}; outcome.withLockedValue { $0 = "clean" } } catch WebSocketError.slowConsumer { outcome.withLockedValue { $0 = "slow" } }
        }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where !app.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        addTeardownBlock { try? await app.stopAsync() }

        let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/slow")!)
        task.resume()
        for _ in 0..<600 { try? await task.send(.string("x")) }
        for _ in 0..<60 where outcome.withLockedValue({ $0 }) == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(outcome.withLockedValue { $0 }, "slow")
    }

    func testCloseFramePayloadValidation() {
        func payload(_ bytes: [UInt8]) -> ByteBuffer { ByteBuffer(bytes: bytes) }
        XCTAssertNil(WebSocketBridge.closeRejection(payload([])))
        XCTAssertNil(WebSocketBridge.closeRejection(payload([0x03, 0xE8]))) // 1000
        XCTAssertNil(WebSocketBridge.closeRejection(payload([0x03, 0xE8, 0x62, 0x79, 0x65]))) // 1000 "bye"
        XCTAssertNotNil(WebSocketBridge.closeRejection(payload([0x03]))) // one byte
        XCTAssertNotNil(WebSocketBridge.closeRejection(payload([0x03, 0xED]))) // 1005 must not be sent
        XCTAssertNotNil(WebSocketBridge.closeRejection(payload([0x00, 0x00]))) // 0
        XCTAssertNotNil(WebSocketBridge.closeRejection(payload([0x03, 0xE8, 0xFF]))) // reason is not UTF-8
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
