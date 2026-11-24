// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore

/// What a NAT does with the port of a socket, seen from two STUN servers (RFC 4787 mapping behaviour). A direct connection
/// between two NATs needs the mapping to be the same whoever the socket talks to; a symmetric NAT gives a new one for each
/// destination, so the address learned from the STUN server is useless to the peer.
enum NATProbe {
    enum Mapping: Equatable {
        /// The same public address and port towards every server asked: a direct connection can work.
        case stable(host: String, port: Int)
        /// A different one per server: it cannot.
        case symmetric
        /// Not enough answers to say; the first one is still the best guess.
        case unknown(host: String, port: Int)
        /// No server answered.
        case unreachable
    }

    /// Asks each server from the same local `port` and compares what they report.
    static func mapping(servers: [(host: String, port: Int)], localPort: Int, group: EventLoopGroup, timeout: TimeAmount = .seconds(3)) async -> Mapping {
        var seen: [(host: String, port: Int)] = []
        for server in servers.prefix(3) {
            if let mapped = try? await STUNClient.reflexiveAddress(server: server.host, port: server.port, localPort: localPort, timeout: timeout, connectTimeout: timeout, group: group) {
                seen.append(mapped)
            }
        }
        return classify(seen)
    }

    static func classify(_ mapped: [(host: String, port: Int)]) -> Mapping {
        guard let first = mapped.first else { return .unreachable }
        guard mapped.count >= 2 else { return .unknown(host: first.host, port: first.port) }
        return mapped.allSatisfy { $0.host == first.host && $0.port == first.port } ? .stable(host: first.host, port: first.port) : .symmetric
    }
}
