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

    let fingerprint: String
    /// Seconds since 1970 when the host signed it.
    let issued: Int
    let candidates: [Candidate]
}

/// A device announcing itself to a host (signed by the device): the host reads the address the rendezvous saw and lets it
/// through its relay.
struct RendezvousKnockRequest: Codable, Sendable, Equatable {
    let hostFingerprint: String
    let issued: Int
}

/// What the host reads back for each knock.
struct RendezvousKnock: Codable, Sendable, Equatable {
    let address: String
    let deviceFingerprint: String
}

/// The host asking for its knocks (signed by the host).
struct RendezvousPoll: Codable, Sendable, Equatable {
    let hostFingerprint: String
    let issued: Int
}

enum RendezvousPath {
    /// A fingerprint as one path segment: base64url, no prefix.
    static func hostID(_ fingerprint: String) -> String {
        fingerprint.replacingOccurrences(of: "SHA256:", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
