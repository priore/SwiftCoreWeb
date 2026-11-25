// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Where a host can be reached from outside its network, signed by the host and kept by the rendezvous for a few minutes.
struct RendezvousRecord: Codable, Sendable, Equatable {
    struct Candidate: Codable, Sendable, Equatable {
        /// `relay` for an address on a TURN server.
        let kind: String
        let host: String
        let port: Int
    }

    var type = RendezvousPayloadType.record
    let fingerprint: String
    /// Seconds since 1970 when the host signed it.
    let issued: Int
    let candidates: [Candidate]
}

/// A device announcing itself to a host (signed by the device): the host reads the address the rendezvous saw and lets it
/// through its relay.
struct RendezvousKnockRequest: Codable, Sendable, Equatable {
    var type = RendezvousPayloadType.knock
    let hostFingerprint: String
    let issued: Int
    /// Where this device is reachable across the internet (`kind` `direct`: the address and port its NAT gave the socket the
    /// device will connect from), signed with the rest so the rendezvous cannot change it. The host connects to it from its
    /// own tunnel port at the same time the device connects to the host (hole punching).
    var candidate: RendezvousRecord.Candidate? = nil
}

/// What the host reads back for each knock.
struct RendezvousKnock: Codable, Sendable, Equatable {
    let address: String
    /// The device's own signed knock, which the host checks itself: the rendezvous cannot invent a device.
    let envelope: SignedEnvelope
}

/// The host asking for its knocks (signed by the host).
struct RendezvousPoll: Codable, Sendable, Equatable {
    var type = RendezvousPayloadType.poll
    let hostFingerprint: String
    let issued: Int
}

/// Tags every signed payload with what it is for, so a signature made for one purpose is not valid for another.
enum RendezvousPayloadType {
    static let record = "record", knock = "knock", poll = "poll"
}

enum RendezvousPath {
    /// A fingerprint as one path segment: base64url, no prefix.
    static func hostID(_ fingerprint: String) -> String {
        fingerprint.replacingOccurrences(of: "SHA256:", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
