// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import CryptoKit
import SwiftCoreWebP2P

final class P2PSecureChannelTests: XCTestCase {
    private let initiatorKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    private let responderKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
    private let salt = Data("salt".utf8)

    private func pair() throws -> (initiator: P2PSecureChannel, responder: P2PSecureChannel) {
        (P2PSecureChannel(keys: try P2PSessionKeys(privateKey: initiatorKey, peerPublicKey: responderKey.publicKey, salt: salt, role: .initiator)),
         P2PSecureChannel(keys: try P2PSessionKeys(privateKey: responderKey, peerPublicKey: initiatorKey.publicKey, salt: salt, role: .responder)))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private let request = P2PMessage(type: .request, id: 7, payload: Data("hello".utf8))

    /// Fixed vector, computed independently (Python `cryptography`: X25519, HKDF-SHA256, ChaCha20-Poly1305) for other platforms.
    /// Private keys: 32 x 0x01 (initiator), 32 x 0x02 (responder); salt "salt"; message type 1, id 7, payload "hello"; counter 0.
    func testKnownVectorMatchesAnIndependentImplementation() throws {
        var channels = try pair()
        let sealed = try channels.initiator.seal(request)
        XCTAssertEqual(hex(sealed.payload), "00000000000000006e1a67ec4b12782e49b38a6f141c27c8e4d59c8b5a")
        XCTAssertEqual(try channels.responder.open(sealed), request)
    }

    func testRoundTripBothDirectionsAndCounterAdvances() throws {
        var channels = try pair()
        let first = try channels.initiator.seal(request)
        let second = try channels.initiator.seal(request)
        XCTAssertNotEqual(first.payload, second.payload)
        XCTAssertEqual(try channels.responder.open(first), request)
        XCTAssertEqual(try channels.responder.open(second), request)

        let reply = P2PMessage(type: .response, id: 7, payload: Data("world".utf8))
        XCTAssertEqual(try channels.initiator.open(try channels.responder.seal(reply)), reply)
    }

    func testReplayAndReorderingAreRefused() throws {
        var channels = try pair()
        let first = try channels.initiator.seal(request)
        let second = try channels.initiator.seal(request)
        _ = try channels.responder.open(second)
        XCTAssertThrowsError(try channels.responder.open(second)) { XCTAssertEqual($0 as? P2PCryptoError, .replayedOrReordered) }
        XCTAssertThrowsError(try channels.responder.open(first)) { XCTAssertEqual($0 as? P2PCryptoError, .replayedOrReordered) }
    }

    func testTamperingWithTypeIdPayloadOrLengthFailsAuthentication() throws {
        var channels = try pair()
        let sealed = try channels.initiator.seal(request)
        let tampered = [
            P2PMessage(type: .error, id: sealed.id, payload: sealed.payload),
            P2PMessage(type: sealed.type, id: 8, payload: sealed.payload),
            P2PMessage(type: sealed.type, id: sealed.id, payload: sealed.payload.dropLast()),
            P2PMessage(type: sealed.type, id: sealed.id, payload: sealed.payload + Data([0])),
            P2PMessage(type: sealed.type, id: sealed.id, payload: { var p = sealed.payload; p[10] ^= 1; return p }()),
            P2PMessage(type: sealed.type, id: sealed.id, payload: { var p = sealed.payload; p[7] ^= 1; return p }()), // counter
        ]
        for message in tampered {
            XCTAssertThrowsError(try channels.responder.open(message)) { XCTAssertEqual($0 as? P2PCryptoError, .authenticationFailed) }
        }
        XCTAssertEqual(try channels.responder.open(sealed), request) // forgeries did not burn the counter
    }

    func testShortPayloadAndWrongKeysAndOwnDirectionAreRefused() throws {
        var channels = try pair()
        XCTAssertThrowsError(try channels.responder.open(P2PMessage(type: .request, id: 1, payload: Data(count: 23)))) {
            XCTAssertEqual($0 as? P2PCryptoError, .malformedSealedPayload)
        }
        let sealed = try channels.initiator.seal(request)
        XCTAssertThrowsError(try channels.initiator.open(sealed)) { XCTAssertEqual($0 as? P2PCryptoError, .authenticationFailed) } // keys are per direction

        var other = P2PSecureChannel(keys: try P2PSessionKeys(privateKey: initiatorKey, peerPublicKey: responderKey.publicKey, salt: Data("other".utf8), role: .responder))
        XCTAssertThrowsError(try other.open(sealed)) { XCTAssertEqual($0 as? P2PCryptoError, .authenticationFailed) } // different salt
    }

    func testLargestPlaintextFitsOneMoreByteDoesNot() throws {
        var channels = try pair()
        let limit = P2PFraming.maxMessageSize - P2PSecureChannel.overhead
        let fits = try channels.initiator.seal(P2PMessage(type: .response, id: 1, payload: Data(count: limit)))
        XCTAssertEqual(fits.payload.count, P2PFraming.maxMessageSize)
        XCTAssertNoThrow(try P2PFraming.encode(fits))
        XCTAssertThrowsError(try channels.initiator.seal(P2PMessage(type: .response, id: 1, payload: Data(count: limit + 1)))) {
            XCTAssertEqual($0 as? P2PCryptoError, .payloadTooLarge)
        }
    }
}
