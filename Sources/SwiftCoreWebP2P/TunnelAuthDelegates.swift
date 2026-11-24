// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore
import NIOSSH

/// Server side: accepts a client only when it authenticates with a public key that `isAuthorized` approves.
/// Passwords are not offered (they exist only inside a pairing session, which is a later step).
struct PublicKeyAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let isAuthorized: @Sendable (NIOSSHPublicKey) -> Bool
    /// Called once the peer is accepted (used to stop the handshake deadline).
    let onAuthenticated: @Sendable () -> Void

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let offered) = request.request, isAuthorized(offered.publicKey) {
            onAuthenticated()
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

/// Client side: authenticates once with `key`; if the server refuses it there is nothing else to offer.
final class PrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else { return nextChallengePromise.fail(TunnelError.authenticationRefused) }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Client side: trusts only the host key the peer was paired with (pinning).
struct PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let isTrusted: @Sendable (NIOSSHPublicKey) -> Bool

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        isTrusted(hostKey) ? validationCompletePromise.succeed(()) : validationCompletePromise.fail(TunnelError.untrustedHostKey)
    }
}
