// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation
import SwiftCoreWeb
import SwiftCoreWebP2P

/// What the host needs to be reachable from another network. The addresses are kept in `UserDefaults`; the TURN shared
/// secret only in the Keychain (`SecretStore`). Nothing is read from a file in the repository.
@MainActor
final class RemoteSettings: ObservableObject {
    private static let secretKey = "turnSharedSecret"
    private let defaults = UserDefaults.standard

    @Published var rendezvous: String { didSet { defaults.set(rendezvous, forKey: "rendezvous") } }
    @Published var turnHost: String { didSet { defaults.set(turnHost, forKey: "turnHost") } }
    @Published var turnPort: String { didSet { defaults.set(turnPort, forKey: "turnPort") } }
    @Published var turnUser: String { didSet { defaults.set(turnUser, forKey: "turnUser") } }
    @Published var turnSecret: String { didSet { SecretStore.write(turnSecret, forKey: Self.secretKey) } }

    init() {
        rendezvous = defaults.string(forKey: "rendezvous") ?? ""
        turnHost = defaults.string(forKey: "turnHost") ?? ""
        turnPort = defaults.string(forKey: "turnPort") ?? "3478"
        turnUser = defaults.string(forKey: "turnUser") ?? "scw"
        turnSecret = SecretStore.read(Self.secretKey) ?? ""
    }

    /// `nil` while the settings are incomplete: the host then stays on the local network.
    func remoteAccess() -> P2PRemoteAccess? {
        guard let url = URL(string: rendezvous), url.host != nil, !turnHost.isEmpty, !turnSecret.isEmpty,
              let port = Int(turnPort) else { return nil }
        return P2PRemoteAccess(
            rendezvous: url,
            relay: .init(host: turnHost, port: port, username: turnUser, sharedSecret: turnSecret)
        )
    }
}
