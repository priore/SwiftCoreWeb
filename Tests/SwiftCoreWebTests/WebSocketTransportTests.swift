// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOConcurrencyHelpers
@testable import SwiftCoreWeb

final class WebSocketTransportTests: XCTestCase {
    func testCustomTransportCarriesMessagesAndClosesOnce() async throws {
        let sent = NIOLockedValueBox<[WebSocketMessage]>([])
        let closes = NIOLockedValueBox(0)
        let socket = WebSocket(transport: .init(
            messages: { AsyncThrowingStream { $0.yield(.text("hi")); $0.finish() } },
            send: { message in sent.withLockedValue { $0.append(message) } },
            close: { _ in closes.withLockedValue { $0 += 1 } }
        ))

        var received: [String] = []
        for try await message in socket.messages() {
            if case .text(let text) = message { received.append(text) }
        }
        try await socket.send("echo")
        try await socket.send(Data([1, 2]))
        try await socket.close()
        try await socket.close()

        XCTAssertEqual(received, ["hi"])
        XCTAssertEqual(sent.withLockedValue { $0.count }, 2)
        XCTAssertEqual(closes.withLockedValue { $0 }, 1)
    }
}
