// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOSSH

/// The host side of pairing: owns the host key, the list of paired devices, and the one-time pairing token.
///
/// - The host key is created on first use and kept in `storage` (the Keychain by default).
/// - A pairing session is opened by the user (never by default), yields a random one-time token, and ends at the first
///   success, after `maxAttempts` tries, or when it expires.
/// - A paired device is identified by the fingerprint of its key; it can then connect with the key alone.
public final class PairingManager: Sendable {
    private struct Session {
        let token: String
        /// A short number to type instead of scanning, valid for the same session and attempts.
        let code: String?
        let expiresAt: Date
        var attemptsLeft: Int
    }

    private struct State {
        var session: Session?
        var devices: [PairedDevice]
        var onRevoke: (@Sendable (String) -> Void)?
        /// A change could not be saved: the stored list still differs from the one in memory until a save succeeds.
        var pendingSave = false
    }

    private static let hostKeyName = "p2p.host-key"
    private static let devicesName = "p2p.devices"

    private let storage: TunnelSecretStorage
    private let now: @Sendable () -> Date
    private let hostKey: NIOSSHPrivateKey
    /// The same key, for signing what the host publishes (the rendezvous record).
    let hostSigningKey: Curve25519.Signing.PrivateKey
    private let state: NIOLockedValueBox<State>

    public init(storage: TunnelSecretStorage = KeychainTunnelStorage(), now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.storage = storage
        self.now = now
        if let stored = storage.read(Self.hostKeyName) {
            // A stored but unreadable key is never replaced silently: the host's identity would change under every paired device.
            guard let raw = Data(base64Encoded: stored), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                throw TunnelError.corruptedStorage
            }
            hostKey = NIOSSHPrivateKey(ed25519Key: key)
            hostSigningKey = key
        } else {
            let key = Curve25519.Signing.PrivateKey()
            guard storage.write(key.rawRepresentation.base64EncodedString(), forKey: Self.hostKeyName) else { throw TunnelError.storageUnavailable }
            hostKey = NIOSSHPrivateKey(ed25519Key: key)
            hostSigningKey = key
        }
        var devices: [PairedDevice] = []
        if let stored = storage.read(Self.devicesName) {
            guard let data = stored.data(using: .utf8), let decoded = try? Self.decoder.decode([PairedDevice].self, from: data) else {
                throw TunnelError.corruptedStorage // not an empty list: the next save would erase every pairing
            }
            devices = decoded
        }
        state = NIOLockedValueBox(State(session: nil, devices: devices, onRevoke: nil, pendingSave: false))
    }

    // MARK: - Host identity

    var hostPrivateKey: NIOSSHPrivateKey { hostKey }
    public var hostPublicKey: NIOSSHPublicKey { hostKey.publicKey }
    public var hostFingerprint: String { TunnelFingerprint.of(hostKey.publicKey) }

    // MARK: - Pairing session

    /// Opens a pairing session and returns its token, replacing any session already open.
    ///
    /// With `withCode` the session also accepts a six-digit code (`pairingCode`), for a device without a camera. The QR
    /// token stays long and random; the code shares the session's attempts, so with five guesses a code is guessed with
    /// probability 5 in a million.
    @discardableResult
    public func openPairing(validFor lifetime: TimeInterval = 120, maxAttempts: Int = 5, withCode: Bool = false) -> String {
        let token = Self.makeToken()
        let session = Session(token: token, code: withCode ? Self.makeCode(digits: 6) : nil, expiresAt: now().addingTimeInterval(lifetime), attemptsLeft: maxAttempts)
        state.withLockedValue { $0.session = session }
        return token
    }

    /// The six-digit code of the open session, when it was opened with one.
    public var pairingCode: String? {
        let current = now()
        return state.withLockedValue { state in
            guard let session = state.session, session.expiresAt > current, session.attemptsLeft > 0 else { return nil }
            return session.code
        }
    }

    public func closePairing() {
        state.withLockedValue { $0.session = nil }
    }

    /// Whether a pairing session is open (not expired, attempts left).
    public var isPairingOpen: Bool {
        let current = now()
        return state.withLockedValue { $0.session.map { $0.expiresAt > current && $0.attemptsLeft > 0 } ?? false }
    }

    /// The payload for the open session, or `nil` when none is open or `host`/the ports cannot form a valid payload. `host` is where the device will connect.
    public func payload(host: String, port: Int, appPort: Int, name: String? = nil, rendezvous: URL? = nil) -> PairingPayload? {
        let current = now()
        guard let session = state.withLockedValue({ $0.session }), session.expiresAt > current, session.attemptsLeft > 0 else { return nil }
        return PairingPayload(host: host, port: port, appPort: appPort, token: session.token, hostKeyFingerprint: hostFingerprint, name: name, rendezvous: rendezvous)
    }

    /// Checks `token` for `device` and, if it is the open session's, registers the device and ends the session.
    /// Every call uses up an attempt, right or wrong.
    func attemptPairing(device: NIOSSHPublicKey, token: String, name: String? = nil) -> Bool {
        let current = now()
        let accepted = state.withLockedValue { state -> Bool in
            guard var session = state.session, session.expiresAt > current, session.attemptsLeft > 0 else {
                state.session = nil
                return false
            }
            session.attemptsLeft -= 1
            let byToken = Self.constantTimeEquals(token, session.token)
            let byCode = session.code.map { Self.constantTimeEquals(token, $0) } ?? false
            let matches = byToken || byCode
            state.session = (matches || session.attemptsLeft == 0) ? nil : session
            return matches
        }
        guard accepted else { return false }
        let id = TunnelFingerprint.of(device)
        return state.withLockedValue { state in
            // A device already paired keeps its date, and its name only if the host's owner renamed it. The new list is saved first: a pairing that could not be
            // made durable is not granted.
            var devices = state.devices
            if let index = devices.firstIndex(where: { $0.id == id }) {
                // A device paired again takes the name it gives now, unless the host's owner renamed it.
                if let name, devices[index].nameSetByHost != true { devices[index].name = name }
            } else {
                devices.append(PairedDevice(id: id, name: name ?? "Device " + id.dropFirst(7).prefix(6), publicKey: String(openSSHPublicKey: device), pairedAt: current))
            }
            guard persist(devices) else { return false }
            state.devices = devices
            state.pendingSave = false
            return true
        }
    }

    // MARK: - Paired devices

    public var devices: [PairedDevice] { state.withLockedValue { $0.devices } }

    /// The paired device that owns `key`, if any.
    func device(for key: NIOSSHPublicKey) -> PairedDevice? {
        let id = TunnelFingerprint.of(key)
        return state.withLockedValue { $0.devices.first { $0.id == id } }
    }

    /// Whether `deviceID` is still paired (used to drop a connection that authenticated just as it was revoked).
    func isPaired(deviceID: String) -> Bool {
        state.withLockedValue { $0.devices.contains { $0.id == deviceID } }
    }

    /// Returns `false` when the device is unknown or the change could not be saved (then nothing changed).
    @discardableResult
    public func rename(deviceID: String, to name: String) -> Bool {
        state.withLockedValue { state in
            guard let index = state.devices.firstIndex(where: { $0.id == deviceID }) else { return false }
            var devices = state.devices
            devices[index].name = name
            devices[index].nameSetByHost = true
            guard persist(devices) else { return false }
            state.devices = devices
            state.pendingSave = false
            return true
        }
    }

    /// Removes a device: it can no longer connect now, and `onRevoke` lets the server drop its open sessions. Returns
    /// whether the device was known. Throws `TunnelError.storageUnavailable` when the removal could not be saved: the
    /// device is already refused in this run but would be paired again after a restart. Calling `revoke` again (with
    /// the same or any id) retries the save until it succeeds.
    @discardableResult
    public func revoke(deviceID: String) throws -> Bool {
        let (removed, saved, handler) = state.withLockedValue { state -> (Bool, Bool, (@Sendable (String) -> Void)?) in
            let before = state.devices.count
            state.devices.removeAll { $0.id == deviceID }
            let removed = state.devices.count < before
            var saved = true
            if removed || state.pendingSave {
                saved = persist(state.devices)
                state.pendingSave = !saved
            }
            return (removed, saved, state.onRevoke)
        }
        if removed { handler?(deviceID) }
        if !saved { throw TunnelError.storageUnavailable }
        return removed
    }

    /// Set by the server to close a revoked device's open connections.
    func setRevocationHandler(_ handler: (@Sendable (String) -> Void)?) {
        state.withLockedValue { $0.onRevoke = handler }
    }

    // MARK: - Helpers

    private func persist(_ devices: [PairedDevice]) -> Bool {
        guard let data = try? Self.encoder.encode(devices), let text = String(data: data, encoding: .utf8) else { return false }
        return storage.write(text, forKey: Self.devicesName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func makeCode(digits: Int) -> String {
        let count = min(max(digits, 4), 9)
        let limit = (0..<count).reduce(1) { value, _ in value * 10 }
        var generator = SystemRandomNumberGenerator()
        let number = Int.random(in: 0..<limit, using: &generator)
        return String(repeating: "0", count: count - String(number).count) + String(number)
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Compares without stopping at the first difference, so timing does not reveal how much of a guess was right.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
