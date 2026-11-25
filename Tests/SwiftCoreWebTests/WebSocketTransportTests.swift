// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import NIOWebSocket
import NIOConcurrencyHelpers
@testable import SwiftCoreWeb

final class WebSocketTransportTests: XCTestCase {
    func testCustomTransportCarriesMessagesAndClosesOnce() async throws {
        let sent = NIOLockedValueBox<[WebSocketMessage]>([])
        let closes = NIOLockedValueBox<[WebSocketErrorCode]>([])
        let socket = WebSocket(transport: .init(
            messages: { AsyncThrowingStream { $0.yield(.text("hi")); $0.finish() } },
            send: { message in sent.withLockedValue { $0.append(message) } },
            close: { code in closes.withLockedValue { $0.append(code) } }
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
        let messages = sent.withLockedValue { $0 }
        guard messages.count == 2, case .text("echo") = messages[0], case .binary(let data) = messages[1] else {
            return XCTFail("unexpected messages: \(messages)")
        }
        XCTAssertEqual(data, Data([1, 2]))
        XCTAssertEqual(closes.withLockedValue { $0 }, [.normalClosure])
    }
}
