// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOCore
import NIOSSH

/// Server side. A paired device authenticates with its key. While a pairing session is open a new device may instead
/// offer the one-time token as a password (its key travelling in the user name) and is registered by it.
struct PairingAuthDelegate: NIOSSHServerUserAuthenticationDelegate {
    let pairing: PairingManager
    /// Called with the device id once the peer is accepted (stops the handshake deadline, registers the connection).
    let onAuthenticated: @Sendable (String) -> Void

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        pairing.isPairingOpen ? [.publicKey, .password] : .publicKey
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        switch request.request {
        case .publicKey(let offered):
            if let device = pairing.device(for: offered.publicKey) {
                onAuthenticated(device.id)
                return responsePromise.succeed(.success)
            }
        case .password(let offered):
            if pairing.isPairingOpen, let device = DeviceUsername.decode(request.username),
               pairing.attemptPairing(device: device, token: offered.password) {
                onAuthenticated(TunnelFingerprint.of(device))
                return responsePromise.succeed(.success)
            }
        default:
            break
        }
        responsePromise.succeed(.failure)
    }
}

/// Client side: offers `credential` once; if the server refuses it there is nothing else to offer.
final class CredentialAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private let credential: TunnelCredential
    private var offered = false

    init(key: NIOSSHPrivateKey, credential: TunnelCredential) {
        self.username = DeviceUsername.encode(key.publicKey)
        self.key = key
        self.credential = credential
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered else { return nextChallengePromise.fail(TunnelError.authenticationRefused) }
        offered = true
        switch credential {
        case .key where availableMethods.contains(.publicKey):
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
        case .pairing(let token) where availableMethods.contains(.password):
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: token))))
        default:
            nextChallengePromise.fail(TunnelError.authenticationRefused)
        }
    }
}

/// Client side: trusts only the host key the peer was paired with (pinning).
struct PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    /// May wait for the user (a fingerprint confirmation) before answering.
    let isTrusted: @Sendable (NIOSSHPublicKey) async -> Bool

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let isTrusted = isTrusted
        let promiseBox = UncheckedSendableBox(validationCompletePromise)
        let keyBox = UncheckedSendableBox(hostKey)
        Task {
            if await isTrusted(keyBox.value) { promiseBox.value.succeed(()) } else { promiseBox.value.fail(TunnelError.untrustedHostKey) }
        }
    }
}
