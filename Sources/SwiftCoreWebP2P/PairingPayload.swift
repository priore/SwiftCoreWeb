// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// What the host shows (as a QR code or a link) for a device to pair: where to connect, the one-time token, and the
/// fingerprint of the host key so the device recognises the right host even on a hostile network.
public struct PairingPayload: Sendable, Equatable {
    public static let scheme = "scw-p2p"

    public var host: String
    /// The tunnel's port.
    public var port: Int
    /// The port of the SCW listener on the host: the only destination the tunnel forwards to.
    public var appPort: Int
    public var token: String
    public var hostKeyFingerprint: String
    /// A label for the host, shown to the user.
    public var name: String?

    public init(host: String, port: Int, appPort: Int, token: String, hostKeyFingerprint: String, name: String? = nil) {
        self.host = host
        self.port = port
        self.appPort = appPort
        self.token = token
        self.hostKeyFingerprint = hostKeyFingerprint
        self.name = name
    }

    /// `scw-p2p://host:port?sp=<app port>&t=<token>&fp=<fingerprint>&n=<name>`
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.port = port
        components.queryItems = [
            URLQueryItem(name: "sp", value: String(appPort)),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "fp", value: hostKeyFingerprint)
        ] + (name.map { [URLQueryItem(name: "n", value: $0)] } ?? [])
        return components.url!
    }

    /// Parses a scanned or pasted link; `nil` when it is not a complete pairing payload.
    public init?(_ string: String) {
        guard let components = URLComponents(string: string), components.scheme == Self.scheme,
              let host = components.host, !host.isEmpty, let port = components.port else { return nil }
        let items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        guard let appPort = items["sp"].flatMap(Int.init), let token = items["t"], !token.isEmpty, let fingerprint = items["fp"], !fingerprint.isEmpty else { return nil }
        self.init(host: host, port: port, appPort: appPort, token: token, hostKeyFingerprint: fingerprint, name: items["n"])
    }
}
