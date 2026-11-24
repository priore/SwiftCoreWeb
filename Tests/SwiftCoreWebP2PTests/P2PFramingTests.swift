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

    /// A hand-built frame, to send what a correct encoder never would.
    private func frame(type: UInt8 = 2, last: Bool, id: UInt64 = 1, index: UInt32, payload: Data) -> Data {
        var data = Data([1, type, last ? 1 : 0, 0])
        withUnsafeBytes(of: id.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: index.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    func testShortNonFinalFragmentIsRefused() {
        var reassembler = P2PReassembler()
        XCTAssertThrowsError(try reassembler.accept(frame(last: false, index: 0, payload: Data()))) {
            XCTAssertEqual($0 as? P2PFramingError, .lengthMismatch)
        }
    }

    func testOversizedMessageIsRefusedByTheReassembler() throws {
        var reassembler = P2PReassembler(maxPartialMessages: 8, maxBufferedBytes: 8 * P2PFraming.maxMessageSize)
        let full = Data(count: P2PFraming.maxFragmentPayload)
        for index in 0..<32 { XCTAssertNil(try reassembler.accept(frame(last: false, index: UInt32(index), payload: full))) }
        XCTAssertThrowsError(try reassembler.accept(frame(last: false, index: 32, payload: full))) {
            XCTAssertEqual($0 as? P2PFramingError, .messageTooLarge)
        }
    }

    func testBufferBudgetIsEnforcedAndReleasedAfterAnError() throws {
        let full = Data(count: P2PFraming.maxFragmentPayload)
        var reassembler = P2PReassembler(maxPartialMessages: 8, maxBufferedBytes: 2 * P2PFraming.maxFragmentPayload)
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 1, index: 0, payload: full)))
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 2, index: 0, payload: full)))
        XCTAssertThrowsError(try reassembler.accept(frame(last: false, id: 3, index: 0, payload: full))) {
            XCTAssertEqual($0 as? P2PFramingError, .bufferBudgetExceeded)
        }
        // Message 1 is untouched by the failure of message 3 and can still finish.
        XCTAssertEqual(try reassembler.accept(frame(last: true, id: 1, index: 1, payload: Data([9]))),
                       P2PMessage(type: .response, id: 1, payload: full + Data([9])))
        // Its bytes were released: a new partial fits again.
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 4, index: 0, payload: full)))
    }

    func testTypeChangeMidMessageAndSlicedInputAreHandled() throws {
        let full = Data(count: P2PFraming.maxFragmentPayload)
        var reassembler = P2PReassembler()
        XCTAssertNil(try reassembler.accept(frame(type: 2, last: false, index: 0, payload: full)))
        XCTAssertThrowsError(try reassembler.accept(frame(type: 4, last: true, index: 1, payload: Data()))) {
            XCTAssertEqual($0 as? P2PFramingError, .unexpectedFragment)
        }

        let wire = Data([0xAA, 0xBB]) + frame(last: true, index: 0, payload: Data("ok".utf8))
        XCTAssertEqual(try reassembler.accept(wire.dropFirst(2)), P2PMessage(type: .response, id: 1, payload: Data("ok".utf8)))
    }

    func testSingleFrameMessageIsAcceptedWhenAllPartialSlotsAreTaken() throws {
        let full = Data(count: P2PFraming.maxFragmentPayload)
        var reassembler = P2PReassembler(maxPartialMessages: 2)
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 1, index: 0, payload: full)))
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 2, index: 0, payload: full)))
        XCTAssertEqual(try reassembler.accept(frame(last: true, id: 3, index: 0, payload: Data("x".utf8))),
                       P2PMessage(type: .response, id: 3, payload: Data("x".utf8)))
    }

    func testFinalFragmentPastMaxSizeAndBudgetErrorOnExistingIdFreeTheirBytes() throws {
        let full = Data(count: P2PFraming.maxFragmentPayload)
        var reassembler = P2PReassembler(maxPartialMessages: 8, maxBufferedBytes: 2 * P2PFraming.maxFragmentPayload)
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 1, index: 0, payload: full)))
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 1, index: 1, payload: full)))
        XCTAssertThrowsError(try reassembler.accept(frame(last: false, id: 1, index: 2, payload: full))) {
            XCTAssertEqual($0 as? P2PFramingError, .bufferBudgetExceeded)
        }
        // Message 1 is gone and its 64 KiB released: two new partials fit again.
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 2, index: 0, payload: full)))
        XCTAssertNil(try reassembler.accept(frame(last: false, id: 3, index: 0, payload: full)))

        var big = P2PReassembler(maxPartialMessages: 8, maxBufferedBytes: 8 * P2PFraming.maxMessageSize)
        for index in 0..<32 { XCTAssertNil(try big.accept(frame(last: false, index: UInt32(index), payload: full))) }
        XCTAssertThrowsError(try big.accept(frame(last: true, index: 32, payload: Data([1])))) {
            XCTAssertEqual($0 as? P2PFramingError, .messageTooLarge)
        }
    }
}
