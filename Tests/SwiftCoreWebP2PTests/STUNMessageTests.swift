// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWebP2P

final class STUNMessageTests: XCTestCase {
    /// RFC 5769 §2.2: sample IPv4 response, with MESSAGE-INTEGRITY (password below) and FINGERPRINT.
    private let rfc5769IPv4Response: [UInt8] = [
        0x01, 0x01, 0x00, 0x3c, 0x21, 0x12, 0xa4, 0x42, 0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae,
        0x80, 0x22, 0x00, 0x0b, 0x74, 0x65, 0x73, 0x74, 0x20, 0x76, 0x65, 0x63, 0x74, 0x6f, 0x72, 0x20,
        0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43,
        0x00, 0x08, 0x00, 0x14, 0x2b, 0x91, 0xf5, 0x99, 0xfd, 0x9e, 0x90, 0xc3, 0x8c, 0x74, 0x89, 0xf9, 0x2a, 0xf9, 0xba, 0x53, 0xf0, 0x6b, 0xe7, 0xd7,
        0x80, 0x28, 0x00, 0x04, 0xc0, 0x7d, 0x4c, 0x96,
    ]
    private let rfc5769Password = Array("VOkJxbRl1RmTxUk/WvJxBt".utf8)

    func testRFC5769ResponseDecodesWithValidFingerprintAndIntegrity() throws {
        let data = Data(rfc5769IPv4Response)
        let (message, integrityOffset) = try STUNMessage.decode(data) // throws on a wrong FINGERPRINT
        XCTAssertEqual(message.method, STUNMessage.Method.binding)
        XCTAssertEqual(message.messageClass, .success)
        let address = try XCTUnwrap(message.xorMappedAddress)
        XCTAssertEqual(address.host, "192.0.2.1")
        XCTAssertEqual(address.port, 32853)
        let offset = try XCTUnwrap(integrityOffset)
        XCTAssertTrue(STUNMessage.integrityIsValid(data, integrityOffset: offset, key: rfc5769Password))
        XCTAssertFalse(STUNMessage.integrityIsValid(data, integrityOffset: offset, key: Array("wrong".utf8)))
    }

    func testIntegrityAndFingerprintRoundTrip() throws {
        let key = Array("secret".utf8)
        let message = STUNMessage(method: STUNMessage.Method.binding, messageClass: .request, attributes: [
            .init(type: STUNMessage.AttributeType.username, value: Array("user".utf8)), // not a multiple of 4: padded
            .init(type: STUNMessage.AttributeType.nonce, value: Array("abcde".utf8)),
        ])
        let data = message.encoded(integrityKey: key, fingerprint: true)
        let (decoded, offset) = try STUNMessage.decode(data)
        XCTAssertEqual(decoded.attribute(STUNMessage.AttributeType.nonce), Array("abcde".utf8))
        XCTAssertTrue(STUNMessage.integrityIsValid(data, integrityOffset: try XCTUnwrap(offset), key: key))
        XCTAssertFalse(STUNMessage.integrityIsValid(data, integrityOffset: try XCTUnwrap(offset), key: Array("other".utf8)))
    }

    func testCorruptedMessagesAreRefused() throws {
        var flipped = rfc5769IPv4Response
        flipped[flipped.count - 1] ^= 0xFF // FINGERPRINT
        XCTAssertThrowsError(try STUNMessage.decode(Data(flipped))) { XCTAssertEqual($0 as? STUNMessage.DecodingError, .badFingerprint) }
        XCTAssertThrowsError(try STUNMessage.decode(Data(rfc5769IPv4Response.dropLast(4)))) { XCTAssertEqual($0 as? STUNMessage.DecodingError, .badLength) }
        XCTAssertThrowsError(try STUNMessage.decode(Data([1, 2, 3]))) { XCTAssertEqual($0 as? STUNMessage.DecodingError, .tooShort) }
        var noCookie = rfc5769IPv4Response
        noCookie[4] = 0
        XCTAssertThrowsError(try STUNMessage.decode(Data(noCookie))) { XCTAssertEqual($0 as? STUNMessage.DecodingError, .notStun) }
    }

    func testBindingRequestRoundTripAndXorAddress() throws {
        let request = STUNMessage(method: STUNMessage.Method.binding, messageClass: .request)
        XCTAssertEqual(request.encoded().count, 20)
        let (decoded, _) = try STUNMessage.decode(request.encoded(fingerprint: true))
        XCTAssertEqual(decoded.transactionID, request.transactionID)
        XCTAssertEqual(decoded.messageClass, .request)

        let attribute = try XCTUnwrap(STUNMessage.xorAddressAttribute(host: "203.0.113.9", port: 54321, transactionID: request.transactionID))
        let response = STUNMessage(method: STUNMessage.Method.binding, messageClass: .success, transactionID: request.transactionID, attributes: [attribute])
        let address = try XCTUnwrap(try STUNMessage.decode(response.encoded()).message.xorMappedAddress)
        XCTAssertEqual(address.host, "203.0.113.9")
        XCTAssertEqual(address.port, 54321)
    }

    func testErrorCodeAttribute() throws {
        let error = STUNMessage(method: STUNMessage.Method.binding, messageClass: .error, attributes: [
            .init(type: STUNMessage.AttributeType.errorCode, value: [0, 0, 4, 1] + Array("Unauthorized".utf8)),
        ])
        let decoded = try STUNMessage.decode(error.encoded()).message
        XCTAssertEqual(decoded.errorCode?.code, 401)
        XCTAssertEqual(decoded.errorCode?.reason, "Unauthorized")
    }
}
