// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import XCTest
import SwiftCoreWeb
import NIOSSH
@testable import SwiftCoreWebP2P

/// The standard `ssh` client of the machine, with a key the host paired, reaches the app through the tunnel: the proof that
/// the protocol is plain SSH and not something only this library speaks.
///
/// The iOS Simulator cannot run `ssh` (its processes have no user database), so this test only prepares the host and a
/// key file for `scripts/p2p-openssh-interop.sh`, which runs `ssh` outside and tells the test what it saw. Without the
/// script (`SCW_INTEROP_DIR` unset) the test is skipped.
final class OpenSSHInteropTests: XCTestCase {
    func testAnOpenSSHClientForwardsARequestToTheHost() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCW_INTEROP_DIR"] else { throw XCTSkip("run scripts/p2p-openssh-interop.sh") }
        let directory = URL(fileURLWithPath: path)

        let appPort = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(appPort)
        let host = try builder.useP2P(storage: InMemoryTunnelStorage())
        let app = builder.build()
        app.mapGet("/hello") { _ in "hello from the host" }
        addTeardownBlock { try? await app.stopAsync() }
        Task { try? await app.runAsync() }
        for _ in 0..<100 where host.tunnelPort == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let tunnelPort = try XCTUnwrap(host.tunnelPort)

        // Pair as any device does, then hand the same key to OpenSSH.
        let deviceStorage = InMemoryTunnelStorage()
        let payload = try XCTUnwrap(host.openPairing(host: "127.0.0.1"))
        let peer = try await SCWPeerConnection.pair(payload, storage: deviceStorage)
        await peer.stop()
        let seed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(deviceStorage.read("p2p.device-key"))))
        let deviceKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

        let keyFile = directory.appendingPathComponent("id_ed25519"), knownHosts = directory.appendingPathComponent("known_hosts")
        try Self.openSSHPrivateKey(deviceKey).write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let hostKey = String(openSSHPublicKey: try XCTUnwrap(host.pairing).hostPublicKey)
        try "[127.0.0.1]:\(tunnelPort) \(hostKey)\n".write(to: knownHosts, atomically: true, encoding: .utf8)
        try "\(tunnelPort) \(appPort)\n".write(to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)

        // The script runs `ssh -W` against the host and writes what came back; wait for it.
        let result = directory.appendingPathComponent("result.txt")
        for _ in 0..<240 where !FileManager.default.fileExists(atPath: result.path) { try await Task.sleep(nanoseconds: 250_000_000) }
        let text = try String(contentsOf: result, encoding: .utf8)
        XCTAssertTrue(text.contains("200 OK") && text.contains("hello from the host"), "ssh -W to the app: \(text)")
        XCTAssertFalse(text.contains("SSH-2.0-OpenSSH"), "a destination outside the allow-list must not be reached: \(text)")
    }

    // MARK: - Helpers

    /// An unencrypted OpenSSH private key file for an Ed25519 key (the `openssh-key-v1` format).
    static func openSSHPrivateKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        func string(_ data: Data) -> Data { var out = Data(UInt32(data.count).bigEndianBytes); out.append(data); return out }
        let type = Data("ssh-ed25519".utf8)
        let pub = key.publicKey.rawRepresentation
        let publicBlob = string(type) + string(pub)
        var body = Data(UInt32(0x1234_5678).bigEndianBytes) + Data(UInt32(0x1234_5678).bigEndianBytes)
        body += string(type) + string(pub) + string(key.rawRepresentation + pub) + string(Data("scw".utf8))
        var pad: UInt8 = 1
        while body.count % 8 != 0 { body.append(pad); pad += 1 }
        var file = Data("openssh-key-v1\0".utf8)
        file += string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data())
        file += Data(UInt32(1).bigEndianBytes) + string(publicBlob) + string(body)
        let base64 = file.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { i -> String in
            let start = base64.index(base64.startIndex, offsetBy: i), end = base64.index(start, offsetBy: min(70, base64.count - i))
            return String(base64[start..<end])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)] }
}
