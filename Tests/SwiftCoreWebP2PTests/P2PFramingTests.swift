// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import SwiftCoreWebP2P

final class P2PFramingTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Fixed vector: other platforms implement the framing against this exact byte sequence.
    func testKnownVector() throws {
        let message = P2PMessage(type: .request, id: 0x0102030405060708, payload: Data("hi".utf8))
        let frames = try P2PFraming.encode(message)
        XCTAssertEqual(frames.map(hex), ["010101000102030405060708000000000002" + "6869"])
    }

    func testEmptyPayloadIsOneFrame() throws {
        let message = P2PMessage(type: .response, id: 1, payload: Data())
        let frames = try P2PFraming.encode(message)
        XCTAssertEqual(frames.count, 1)
        var reassembler = P2PReassembler()
        XCTAssertEqual(try reassembler.accept(frames[0]), message)
    }

    func testLargeMessageSplitsAndReassemblesWithInterleaving() throws {
        let big = P2PMessage(type: .response, id: 7, payload: Data((0..<100_000).map { UInt8($0 % 251) }))
        let small = P2PMessage(type: .webSocketMessage, id: 8, payload: Data("x".utf8))
        let bigFrames = try P2PFraming.encode(big)
        XCTAssertEqual(bigFrames.count, 4) // 100_000 / 32_768
        XCTAssertTrue(bigFrames.dropLast().allSatisfy { $0.count == P2PFraming.headerSize + P2PFraming.maxFragmentPayload })

        var reassembler = P2PReassembler()
        var done: [P2PMessage] = []
        for (index, frame) in bigFrames.enumerated() {
            if let message = try reassembler.accept(frame) { done.append(message) }
            if index == 1, let message = try reassembler.accept(try P2PFraming.encode(small)[0]) { done.append(message) }
        }
        XCTAssertEqual(done, [small, big])
    }

    func testMaxSizeAcceptedAndOneOverRefused() throws {
        let max = P2PMessage(type: .request, id: 1, payload: Data(count: P2PFraming.maxMessageSize))
        var reassembler = P2PReassembler()
        var result: P2PMessage?
        for frame in try P2PFraming.encode(max) { result = try reassembler.accept(frame) ?? result }
        XCTAssertEqual(result, max)

        let over = P2PMessage(type: .request, id: 1, payload: Data(count: P2PFraming.maxMessageSize + 1))
        XCTAssertThrowsError(try P2PFraming.encode(over)) { XCTAssertEqual($0 as? P2PFramingError, .messageTooLarge) }
    }

    func testMalformedFramesAreRefused() throws {
        let good = try P2PFraming.encode(P2PMessage(type: .request, id: 1, payload: Data("ab".utf8)))[0]
        func refused(_ mutate: (inout Data) -> Void, _ expected: P2PFramingError, file: StaticString = #filePath, line: UInt = #line) {
            var frame = good
            mutate(&frame)
            var reassembler = P2PReassembler()
            XCTAssertThrowsError(try reassembler.accept(frame), file: file, line: line) {
                XCTAssertEqual($0 as? P2PFramingError, expected, file: file, line: line)
            }
        }
        refused({ $0[0] = 2 }, .unsupportedVersion(2))
        refused({ $0[1] = 99 }, .unknownMessageType(99))
        refused({ $0[2] |= 0x80 }, .reservedBitsSet)
        refused({ $0[3] = 1 }, .reservedBitsSet)
        refused({ $0.removeLast() }, .lengthMismatch)
        refused({ $0.append(0) }, .lengthMismatch)
        refused({ $0 = $0.prefix(5) }, .truncatedFrame)
        refused({ $0[15] = 1 }, .unexpectedFragment) // first fragment must be index 0
    }

    func testOutOfOrderFragmentAndPartialLimit() throws {
        let frames = try P2PFraming.encode(P2PMessage(type: .response, id: 9, payload: Data(count: 70_000)))
        var reassembler = P2PReassembler()
        XCTAssertNil(try reassembler.accept(frames[0]))
        XCTAssertThrowsError(try reassembler.accept(frames[2])) { XCTAssertEqual($0 as? P2PFramingError, .unexpectedFragment) }

        var limited = P2PReassembler(maxPartialMessages: 2)
        for id in 1...2 { XCTAssertNil(try limited.accept(try P2PFraming.encode(P2PMessage(type: .response, id: UInt64(id), payload: Data(count: 40_000)))[0])) }
        let third = try P2PFraming.encode(P2PMessage(type: .response, id: 3, payload: Data(count: 40_000)))[0]
        XCTAssertThrowsError(try limited.accept(third)) { XCTAssertEqual($0 as? P2PFramingError, .tooManyPartialMessages) }
    }
}
