// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation

/// Talks to a `P2PRendezvous`. Everything it sends is signed, and what it reads is checked against the key it was told to
/// trust, so a rendezvous (or whoever sits between) can withhold or delay information but not forge it.
struct RendezvousClient: Sendable {
    enum Failure: Error, Equatable {
        case badResponse(status: Int)
        case untrustedRecord
    }

    let baseURL: URL
    private let session: URLSession
    /// A record older than this is not believed (a captured one replayed later).
    private let maxRecordAge = 900

    init(baseURL: URL, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Host

    func publish(_ candidates: [RendezvousRecord.Candidate], hostKey: Curve25519.Signing.PrivateKey, hostFingerprint: String) async throws {
        let record = RendezvousRecord(fingerprint: hostFingerprint, issued: Self.now, candidates: candidates)
        _ = try await send("PUT", hostPath(hostFingerprint), envelope: .sign(JSONEncoder().encode(record), with: hostKey))
    }

    /// A device that knocked, as the host verified it: the signature is the device's own and is for this host.
    struct Knock: Equatable, Sendable {
        let address: String
        let deviceFingerprint: String
        /// The device's own direct address, when it sent one.
        let direct: RendezvousRecord.Candidate?
    }

    /// The devices that knocked since the last call. The rendezvous only vouches for the address; who knocked is checked here.
    func collectKnocks(hostKey: Curve25519.Signing.PrivateKey, hostFingerprint: String) async throws -> [Knock] {
        let poll = RendezvousPoll(hostFingerprint: hostFingerprint, issued: Self.now)
        let data = try await send("POST", hostPath(hostFingerprint) + "/knocks/collect", envelope: .sign(JSONEncoder().encode(poll), with: hostKey))
        return try JSONDecoder().decode([RendezvousKnock].self, from: data).compactMap { knock in
            guard let (payload, signer) = knock.envelope.verified(),
                  let request = try? JSONDecoder().decode(RendezvousKnockRequest.self, from: payload),
                  request.type == RendezvousPayloadType.knock, request.hostFingerprint == hostFingerprint,
                  abs(Self.now - request.issued) <= 300 else { return nil }
            return Knock(address: knock.address, deviceFingerprint: signer, direct: request.candidate.flatMap { $0.kind == "direct" ? $0 : nil })
        }
    }

    // MARK: - Device

    func knock(hostFingerprint: String, deviceKey: Curve25519.Signing.PrivateKey, candidate: RendezvousRecord.Candidate? = nil) async throws {
        let request = RendezvousKnockRequest(hostFingerprint: hostFingerprint, issued: Self.now, candidate: candidate)
        _ = try await send("POST", hostPath(hostFingerprint) + "/knocks", envelope: .sign(JSONEncoder().encode(request), with: deviceKey))
    }

    /// The host's candidates, or `nil` when it has published none. Throws `untrustedRecord` when what came back was not
    /// signed by `hostFingerprint`'s key, is for someone else, or is too old.
    func candidates(hostFingerprint: String) async throws -> [RendezvousRecord.Candidate]? {
        let data: Data
        do { data = try await send("GET", hostPath(hostFingerprint), envelope: nil) } catch Failure.badResponse(status: 404) { return nil }
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: data), let (payload, signer) = envelope.verified(),
              signer == hostFingerprint, let record = try? JSONDecoder().decode(RendezvousRecord.self, from: payload),
              record.fingerprint == hostFingerprint, abs(Self.now - record.issued) <= maxRecordAge else { throw Failure.untrustedRecord }
        return record.candidates
    }

    // MARK: - Transport

    private func hostPath(_ fingerprint: String) -> String { "p2p/v1/hosts/" + RendezvousPath.hostID(fingerprint) }

    private func send(_ method: String, _ path: String, envelope: SignedEnvelope?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = method
        if let envelope {
            request.httpBody = try JSONEncoder().encode(envelope)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.badResponse(status: status) }
        return data
    }

    private static var now: Int { Int(Date().timeIntervalSince1970) }
}
