// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Testing
import Foundation
@testable import SwiftCoreWeb

/// `isRunning` must mean "listening": it used to turn `true` before the bind and stay `true` after a failed bind.
@Suite(.serialized)
struct EngineLifecycleTests {
    private func makeApp(port: Int) -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        app.mapGet("/ping") { _ in "pong" }
        return app
    }

    /// Holds a listening socket on `port`, so the engine's bind fails.
    private func occupy(_ port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        return fd
    }

    private func ping(_ port: Int) async -> Int? {
        let url = URL(string: "http://127.0.0.1:\(port)/ping")!
        return (try? await URLSession(configuration: .ephemeral).data(from: url)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    @Test func failedBindLeavesIsRunningFalseAndAllowsARetry() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let app = makeApp(port: port)
        let blocker = try occupy(port)

        let failed = Task { () -> Bool in
            do { try await app.runAsync(); return false } catch { return true }
        }
        // The bind must fail (not hang) and leave no engine registered.
        #expect(try await waitUntil { await failed.isCancelled == false && !app.isRunning })
        let threw = await failed.value
        #expect(threw)
        #expect(!app.isRunning)
        close(blocker)

        // Same instance, port free: starts and answers.
        let server = Task { try await app.runAsync() }
        defer { server.cancel(); Task { try? await app.stopAsync() } }
        #expect(try await waitUntil { await ping(port) == 200 })
        #expect(app.isRunning)
    }

    @Test func isRunningIsFalseUntilListeningAndAfterStop() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let app = makeApp(port: port)
        #expect(!app.isRunning)
        let server = Task { try await app.runAsync() }
        defer { server.cancel() }
        #expect(try await waitUntil { await ping(port) == 200 })
        #expect(app.isRunning)

        try await app.stopAsync()
        #expect(!app.isRunning)
        try await app.stopAsync() // idempotent
        #expect(try await waitUntil { await ping(port) == nil })

        // Restart on the same port.
        let again = Task { try await app.runAsync() }
        defer { again.cancel(); Task { try? await app.stopAsync() } }
        #expect(try await waitUntil { await ping(port) == 200 })
        #expect(app.isRunning)
    }
}
