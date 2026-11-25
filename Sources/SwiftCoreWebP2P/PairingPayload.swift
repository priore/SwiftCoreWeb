// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// What the host shows (as a QR code or a link) for a device to pair: where to connect, the one-time token, and the
/// fingerprint of the host key so the device recognises the right host even on a hostile network.
///
/// Built only through validating initialisers, so `link` can always be produced.
public struct PairingPayload: Sendable, Equatable, CustomStringConvertible {
    public static let scheme = "scw-p2p"

    public let host: String
    /// The tunnel's port.
    public let port: Int
    /// The port of the SCW listener on the host: the only destination the tunnel forwards to.
    public let appPort: Int
    public let token: String
    public let hostKeyFingerprint: String
    /// A label for the host, shown to the user.
    public let name: String?
    /// A rendezvous (`P2PRendezvous`) a device can use to reach the host from another network.
    public let rendezvous: URL?

    /// `nil` when `host` is empty or has characters a host cannot have, or a port is outside 1...65535. An IPv6
    /// address is given without brackets.
    public init?(host: String, port: Int, appPort: Int, token: String, hostKeyFingerprint: String, name: String? = nil, rendezvous: URL? = nil) {
        guard Self.isValidHost(host), rendezvous.map(Self.isValidRendezvous) ?? true, (1...65_535).contains(port), (1...65_535).contains(appPort),
              !token.isEmpty, !hostKeyFingerprint.isEmpty else { return nil }
        self.host = host
        self.port = port
        self.appPort = appPort
        self.token = token
        self.hostKeyFingerprint = hostKeyFingerprint
        self.name = name
        self.rendezvous = rendezvous
    }

    /// `scw-p2p://host:port?sp=<app port>&t=<token>&fp=<fingerprint>&n=<name>` (an IPv6 host in brackets).
    public var link: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        var query = "sp=\(appPort)&t=\(Self.encode(token))&fp=\(Self.encode(hostKeyFingerprint))"
        if let name { query += "&n=\(Self.encode(name))" }
        if let rendezvous { query += "&rv=\(Self.encode(rendezvous.absoluteString))" }
        return "\(Self.scheme)://\(authority):\(port)?\(query)"
    }

    /// Parses a scanned or pasted link; `nil` when it is not a complete, well-formed pairing payload.
    public init?(_ string: String) {
        guard let components = URLComponents(string: string), components.scheme?.lowercased() == Self.scheme,
              var host = components.host, let port = components.port else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]"), host.contains(":") { host = String(host.dropFirst().dropLast()) }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, items.updateValue(value, forKey: item.name) == nil else { return nil } // no duplicates
        }
        guard let appPort = items["sp"].flatMap(Self.parsePort), let token = items["t"], let fingerprint = items["fp"] else { return nil }
        var rendezvous: URL?
        if let text = items["rv"] {
            guard let url = URL(string: text) else { return nil } // present but unreadable: not a payload to trust
            rendezvous = url
        }
        self.init(host: host, port: port, appPort: appPort, token: token, hostKeyFingerprint: fingerprint, name: items["n"].flatMap { $0.isEmpty ? nil : $0 }, rendezvous: rendezvous)
    }

    /// Hides the token: a payload must not end up in logs through string interpolation.
    public var description: String { "PairingPayload(host: \(host), port: \(port))" }

    /// A DNS name or IPv4 address (ASCII letters, digits, `.`, `-`, `_`), or an IPv6 address (hex digits, `:` and `.`, at
    /// least two colons). Non-ASCII names are refused: a link must parse the same on every OS version.
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.allSatisfy(\.isASCII) else { return false }
        if host.contains(":") {
            return host.filter { $0 == ":" }.count >= 2 && host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        return host.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    /// An http(s) URL with a host, nothing else: it is shown in a link people scan.
    private static func isValidRendezvous(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return false }
        return url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    private static func parsePort(_ text: String) -> Int? {
        text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) ? Int(text) : nil
    }

    /// Percent-encodes everything but unreserved characters, so `+`, `&` and `=` survive any query parser.
    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}
