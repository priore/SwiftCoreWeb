// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation

/// A STUN message (RFC 8489 §5), also the framing TURN (RFC 8656, RFC 6062) uses.
struct STUNMessage: Equatable, Sendable {
    static let magicCookie: UInt32 = 0x2112_A442
    static let headerSize = 20

    enum AttributeType {
        static let username: UInt16 = 0x0006
        static let messageIntegrity: UInt16 = 0x0008
        static let errorCode: UInt16 = 0x0009
        static let realm: UInt16 = 0x0014
        static let nonce: UInt16 = 0x0015
        static let xorMappedAddress: UInt16 = 0x0020
        static let software: UInt16 = 0x8022
        static let fingerprint: UInt16 = 0x8028
    }

    enum Method {
        static let binding: UInt16 = 0x0001
    }

    enum Class: UInt16 {
        case request = 0x0000, indication = 0x0010, success = 0x0100, error = 0x0110
    }

    struct Attribute: Equatable, Sendable {
        let type: UInt16
        let value: [UInt8]
    }

    enum DecodingError: Error, Equatable {
        case tooShort, notStun, badLength, badFingerprint, truncatedAttribute
    }

    let method: UInt16
    let messageClass: Class
    let transactionID: [UInt8]
    var attributes: [Attribute]

    init(method: UInt16, messageClass: Class, transactionID: [UInt8]? = nil, attributes: [Attribute] = []) {
        self.method = method
        self.messageClass = messageClass
        self.transactionID = transactionID ?? (0..<12).map { _ in UInt8.random(in: 0...255) }
        self.attributes = attributes
    }

    func attribute(_ type: UInt16) -> [UInt8]? { attributes.first { $0.type == type }?.value }

    // MARK: - Encoding

    /// The message on the wire. `integrityKey` appends MESSAGE-INTEGRITY (HMAC-SHA1, §14.5), `fingerprint` the FINGERPRINT
    /// attribute (§14.7), which always comes last.
    func encoded(integrityKey: [UInt8]? = nil, fingerprint: Bool = false) -> Data {
        var body = [UInt8]()
        for attribute in attributes { body += Self.encode(attribute) }

        func header(length: Int) -> [UInt8] {
            var bytes = [UInt8]()
            bytes += Self.bytes(of: (method & 0x000F) | ((method & 0x0070) << 1) | ((method & 0x0F80) << 2) | messageClass.rawValue)
            bytes += Self.bytes(of: UInt16(length))
            bytes += Self.bytes(of: Self.magicCookie)
            bytes += transactionID
            return bytes
        }

        if let key = integrityKey {
            // The length in the header counts MESSAGE-INTEGRITY itself (and nothing after it) while the MAC is computed.
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: header(length: body.count + 24) + body, using: SymmetricKey(data: key))
            body += Self.encode(Attribute(type: AttributeType.messageIntegrity, value: Array(mac)))
        }
        if fingerprint {
            let crc = Self.crc32(header(length: body.count + 8) + body) ^ 0x5354_554E
            body += Self.encode(Attribute(type: AttributeType.fingerprint, value: Self.bytes(of: crc)))
        }
        return Data(header(length: body.count) + body)
    }

    // MARK: - Decoding

    /// Parses one complete message. A FINGERPRINT attribute, when present, must be correct.
    static func decode(_ data: Data) throws -> (message: STUNMessage, integrityOffset: Int?) {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { throw DecodingError.tooShort }
        guard bytes[0] & 0xC0 == 0, readUInt32(bytes, 4) == magicCookie else { throw DecodingError.notStun }
        let length = Int(readUInt16(bytes, 2))
        guard length % 4 == 0, bytes.count == headerSize + length else { throw DecodingError.badLength }

        let type = readUInt16(bytes, 0)
        guard let messageClass = Class(rawValue: type & 0x0110) else { throw DecodingError.notStun }
        let method = (type & 0x000F) | ((type & 0x00E0) >> 1) | ((type & 0x3E00) >> 2)

        var attributes: [Attribute] = []
        var integrityOffset: Int?
        var offset = headerSize
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { throw DecodingError.truncatedAttribute }
            let attributeType = readUInt16(bytes, offset)
            let valueLength = Int(readUInt16(bytes, offset + 2))
            let end = offset + 4 + valueLength
            guard end <= bytes.count else { throw DecodingError.truncatedAttribute }
            let value = Array(bytes[(offset + 4)..<end])
            if attributeType == AttributeType.messageIntegrity, integrityOffset == nil { integrityOffset = offset }
            if attributeType == AttributeType.fingerprint {
                let expected = crc32(Array(bytes[0..<offset]) .withLength(offset - headerSize + 8)) ^ 0x5354_554E
                guard value == Self.bytes(of: expected) else { throw DecodingError.badFingerprint }
            }
            attributes.append(Attribute(type: attributeType, value: value))
            offset = end + (4 - valueLength % 4) % 4
        }
        let message = STUNMessage(method: method, messageClass: messageClass, transactionID: Array(bytes[8..<20]), attributes: attributes)
        return (message, integrityOffset)
    }

    /// Whether the MESSAGE-INTEGRITY of `data` (a message `decode` returned `integrityOffset` for) matches `key`.
    static func integrityIsValid(_ data: Data, integrityOffset: Int, key: [UInt8]) -> Bool {
        let bytes = [UInt8](data)
        guard integrityOffset + 24 <= bytes.count else { return false }
        // The MAC covers the message up to the attribute, with the header length counting the attribute itself.
        let covered = Array(bytes[0..<integrityOffset]).withLength(integrityOffset - headerSize + 24)
        let expected = HMAC<Insecure.SHA1>.authenticationCode(for: covered, using: SymmetricKey(data: key))
        return Array(bytes[(integrityOffset + 4)..<(integrityOffset + 24)]) == Array(expected)
    }

    // MARK: - Addresses and errors

    /// The XOR-MAPPED-ADDRESS of a Binding success response (§14.2): the sender's address as the server saw it.
    var xorMappedAddress: (host: String, port: Int)? {
        guard let value = attribute(AttributeType.xorMappedAddress) else { return nil }
        return Self.decodeXorAddress(value, transactionID: transactionID)
    }

    /// The code (for example 401) and reason of an ERROR-CODE attribute (§14.8).
    var errorCode: (code: Int, reason: String)? {
        guard let value = attribute(AttributeType.errorCode), value.count >= 4 else { return nil }
        return (Int(value[2] & 0x07) * 100 + Int(value[3]), String(decoding: value[4...], as: UTF8.self))
    }

    static func decodeXorAddress(_ value: [UInt8], transactionID: [UInt8]) -> (host: String, port: Int)? {
        guard value.count >= 8 else { return nil }
        let port = Int(readUInt16(value, 2) ^ UInt16(magicCookie >> 16))
        let mask = bytes(of: magicCookie) + transactionID
        switch value[1] {
        case 0x01:
            return ((0..<4).map { String(value[4 + $0] ^ mask[$0]) }.joined(separator: "."), port)
        case 0x02 where value.count >= 20:
            let raw = (0..<16).map { value[4 + $0] ^ mask[$0] }
            let groups = stride(from: 0, to: 16, by: 2).map { String(UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]), radix: 16) }
            return (groups.joined(separator: ":"), port)
        default:
            return nil
        }
    }

    static func xorAddressAttribute(host: String, port: Int, transactionID: [UInt8]) -> Attribute? {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, let port = UInt16(exactly: port) else { return nil }
        let mask = bytes(of: magicCookie) + transactionID
        let xoredPort = port ^ UInt16(magicCookie >> 16)
        return Attribute(type: AttributeType.xorMappedAddress, value: [0, 0x01] + bytes(of: xoredPort) + zip(parts, mask).map { $0 ^ $1 })
    }

    // MARK: - Helpers

    private static func encode(_ attribute: Attribute) -> [UInt8] {
        let padding = (4 - attribute.value.count % 4) % 4
        return bytes(of: attribute.type) + bytes(of: UInt16(attribute.value.count)) + attribute.value + [UInt8](repeating: 0, count: padding)
    }

    static func bytes(of value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    static func bytes(of value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * UInt32($0))) & 0xFF) } }
    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

private extension Array where Element == UInt8 {
    /// A copy with the header's length field set to `length` (the MAC and the CRC cover a header that already counts them).
    func withLength(_ length: Int) -> [UInt8] {
        var copy = self
        copy[2] = UInt8(length >> 8)
        copy[3] = UInt8(length & 0xFF)
        return copy
    }
}
