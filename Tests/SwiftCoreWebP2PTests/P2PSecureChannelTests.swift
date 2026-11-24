// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
import CryptoKit
@testable import SwiftCoreWebP2P

final class P2PSecureChannelTests: XCTestCase {
    // Private keys 0x01... and 0x02...: the first has the smaller public key, so it is the initiator.
    private let initiatorKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    private let responderKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
    private let salt = Data("salt".utf8)
    private let request = P2PMessage(type: .request, id: 7, payload: Data("hello".utf8))

    private func initiatorSide(salt: Data? = nil) throws -> P2PSecureChannel {
        try P2PSecureChannel(privateKey: initiatorKey, peerPublicKey: responderKey.publicKey, salt: salt ?? self.salt)
    }

    private func responderSide(salt: Data? = nil) throws -> P2PSecureChannel {
        try P2PSecureChannel(privateKey: responderKey, peerPublicKey: initiatorKey.publicKey, salt: salt ?? self.salt)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Fixed vector, computed independently (Python `cryptography`: X25519, HKDF-SHA256, ChaCha20-Poly1305) for other platforms.
    /// Private keys: 32 x 0x01 and 32 x 0x02 (the first has the smaller public key and sends with the initiator->responder
    /// key); salt "salt"; message type 1, id 7, payload "hello"; counter 0.
    func testKnownVectorMatchesAnIndependentImplementation() throws {
        var initiator = try initiatorSide()
        var responder = try responderSide()
        let sealed = try initiator.seal(request)
        XCTAssertEqual(hex(sealed.payload), "00000000000000006e1a67ec4b12782e49b38a6f141c27c8e4d59c8b5a")
        XCTAssertEqual(try responder.open(sealed), request)
    }

    func testRoundTripBothDirectionsAndCounterAdvances() throws {
        var initiator = try initiatorSide()
        var responder = try responderSide()
        let first = try initiator.seal(request)
        let second = try initiator.seal(request)
        XCTAssertNotEqual(first.payload, second.payload)
        XCTAssertEqual(try responder.open(first), request)
        XCTAssertEqual(try responder.open(second), request)

        let reply = P2PMessage(type: .response, id: 7, payload: Data("world".utf8))
        XCTAssertEqual(try initiator.open(try responder.seal(reply)), reply)
    }

    func testReplayGapAndReorderingAreRefused() throws {
        var initiator = try initiatorSide()
        var responder = try responderSide()
        let first = try initiator.seal(request)
        let second = try initiator.seal(request)
        let third = try initiator.seal(request)
        _ = try responder.open(first)
        XCTAssertThrowsError(try responder.open(first)) { XCTAssertEqual($0 as? P2PCryptoError, .unexpectedCounter) } // replay
        XCTAssertThrowsError(try responder.open(third)) { XCTAssertEqual($0 as? P2PCryptoError, .unexpectedCounter) } // dropped message
        XCTAssertEqual(try responder.open(second), request) // a refused message did not advance the counter
    }

    func testTamperingWithTypeIdPayloadOrLengthFailsAuthentication() throws {
        var initiator = try initiatorSide()
        var responder = try responderSide()
        let sealed = try initiator.seal(request)
        let tampered = [
            P2PMessage(type: .error, id: sealed.id, payload: sealed.payload),
            P2PMessage(type: sealed.type, id: 8, payload: sealed.payload),
            P2PMessage(type: sealed.type, id: sealed.id, payload: sealed.payload.dropLast()),
            P2PMessage(type: sealed.type, id: sealed.id, payload: sealed.payload + Data([0])),
            P2PMessage(type: sealed.type, id: sealed.id, payload: { var p = sealed.payload; p[10] ^= 1; return p }()),
            P2PMessage(type: sealed.type, id: sealed.id, payload: { var p = sealed.payload; p[7] ^= 1; return p }()), // counter
        ]
        for message in tampered {
            XCTAssertThrowsError(try responder.open(message)) { XCTAssertEqual($0 as? P2PCryptoError, .authenticationFailed) }
        }
        XCTAssertEqual(try responder.open(sealed), request) // forgeries did not burn the counter
    }

    func testSlicedPayloadIsOpened() throws {
        var initiator = try initiatorSide()
        var responder = try responderSide()
        let sealed = try initiator.seal(request)
        let padded = Data([0xAA, 0xBB]) + sealed.payload
        XCTAssertEqual(try responder.open(P2PMessage(type: sealed.type, id: sealed.id, payload: padded.dropFirst(2))), request)
    }

    func testShortPayloadWrongDirectionAndWrongSaltAreRefused() throws {
        var initiator = try initiatorSide()
        var responder = try responderSide()
        XCTAssertThrowsError(try responder.open(P2PMessage(type: .request, id: 1, payload: Data(count: 23)))) {
            XCTAssertEqual($0 as? P2PCryptoError, .malformedSealedPayload)
        }
        let sealed = try initiator.seal(request)
        XCTAssertThrowsError(try initiator.open(sealed)) { XCTAssertEqual($0 as? P2PCryptoError, .authenticationFailed) } // keys are per direction

        var otherSalt = try responderSide(salt: Data("other".utf8))
        XCTAssertThrowsError(try otherSalt.open(sealed)) { XCTAssertEqual($0 as? P2PCryptoError, .authenticationFailed) }
    }

    func testRolesComeFromTheKeysAndDegenerateHandshakesAreRefused() throws {
        // Same private key on both sides (reflection / identical keys): no roles can be assigned.
        XCTAssertThrowsError(try { _ = try P2PSecureChannel(privateKey: initiatorKey, peerPublicKey: initiatorKey.publicKey, salt: salt) }()) {
            XCTAssertEqual($0 as? P2PCryptoError, .identicalPublicKeys)
        }
        XCTAssertThrowsError(try { _ = try initiatorSide(salt: Data()) }()) { XCTAssertEqual($0 as? P2PCryptoError, .emptySalt) }
    }

    func testCounterExhaustionAndLargestPlaintext() throws {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        var exhausted = P2PSecureChannel(sendKey: key, receiveKey: key, sendCounter: .max)
        XCTAssertThrowsError(try exhausted.seal(request)) { XCTAssertEqual($0 as? P2PCryptoError, .counterExhausted) }
        var lastUsable = P2PSecureChannel(sendKey: key, receiveKey: key, sendCounter: .max - 1)
        XCTAssertNoThrow(try lastUsable.seal(request))
        XCTAssertThrowsError(try lastUsable.seal(request)) { XCTAssertEqual($0 as? P2PCryptoError, .counterExhausted) }

        var initiator = try initiatorSide()
        let limit = P2PFraming.maxMessageSize - P2PSecureChannel.overhead
        let fits = try initiator.seal(P2PMessage(type: .response, id: 1, payload: Data(count: limit)))
        XCTAssertEqual(fits.payload.count, P2PFraming.maxMessageSize)
        XCTAssertNoThrow(try P2PFraming.encode(fits))
        XCTAssertThrowsError(try initiator.seal(P2PMessage(type: .response, id: 1, payload: Data(count: limit + 1)))) {
            XCTAssertEqual($0 as? P2PCryptoError, .payloadTooLarge)
        }
    }
}
