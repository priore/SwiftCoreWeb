// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Crypto
import Foundation
import Network

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

    /// Waits between the attempts of a call that is safe to repeat (so there are `retryDelays.count + 1` attempts).
    private let retryDelays: [TimeInterval]

    init(baseURL: URL, session: URLSession = URLSession(configuration: .ephemeral), retryDelays: [TimeInterval] = [0.5, 1]) {
        self.baseURL = baseURL
        self.session = session
        self.retryDelays = retryDelays
    }

    /// Whether a failure is worth another try: the network or the server had a hiccup, as opposed to a request that was
    /// refused (a repeat would be refused again) or a task that was cancelled.
    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? Failure, case .badResponse(let status) = failure { return status == 429 || (500...599).contains(status) }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost: return true
        default: return false
        }
    }

    // MARK: - Host

    func publish(_ candidates: [RendezvousRecord.Candidate], hostKey: Curve25519.Signing.PrivateKey, hostFingerprint: String) async throws {
        let record = RendezvousRecord(fingerprint: hostFingerprint, issued: Self.now, candidates: candidates)
        _ = try await send("PUT", hostPath(hostFingerprint), envelope: .sign(JSONEncoder().encode(record), with: hostKey), repeatable: true) // a PUT of the same record
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
            return Knock(address: knock.address, deviceFingerprint: signer, direct: request.candidate.flatMap { candidate in
                // The host will connect out to this: only the address the rendezvous saw the knock come from, on a real port.
                candidate.kind == "direct" && candidate.host == knock.address && (1...65_535).contains(candidate.port) && IPv4Address(candidate.host) != nil ? candidate : nil
            })
        }
    }

    // MARK: - Device

    func knock(hostFingerprint: String, deviceKey: Curve25519.Signing.PrivateKey, candidate: RendezvousRecord.Candidate? = nil) async throws {
        let request = RendezvousKnockRequest(hostFingerprint: hostFingerprint, issued: Self.now, candidate: candidate)
        _ = try await send("POST", hostPath(hostFingerprint) + "/knocks", envelope: .sign(JSONEncoder().encode(request), with: deviceKey), repeatable: true) // replaces this device's earlier knock
    }

    /// The host's candidates, or `nil` when it has published none. Throws `untrustedRecord` when what came back was not
    /// signed by `hostFingerprint`'s key, is for someone else, or is too old.
    func candidates(hostFingerprint: String) async throws -> [RendezvousRecord.Candidate]? {
        let data: Data
        do { data = try await send("GET", hostPath(hostFingerprint), envelope: nil, repeatable: true) } catch Failure.badResponse(status: 404) { return nil }
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: data), let (payload, signer) = envelope.verified(),
              signer == hostFingerprint, let record = try? JSONDecoder().decode(RendezvousRecord.self, from: payload),
              record.fingerprint == hostFingerprint, abs(Self.now - record.issued) <= maxRecordAge else { throw Failure.untrustedRecord }
        return record.candidates
    }

    // MARK: - Transport

    private func hostPath(_ fingerprint: String) -> String { "p2p/v1/hosts/" + RendezvousPath.hostID(fingerprint) }

    /// `repeatable` calls give the same result however many times they are made, so a transient failure is retried; the others
    /// (collecting knocks empties them) are sent once and the caller decides.
    private func send(_ method: String, _ path: String, envelope: SignedEnvelope?, repeatable: Bool = false) async throws -> Data {
        var attempt = 0
        while true {
            do { return try await sendOnce(method, path, envelope: envelope) } catch {
                guard repeatable, attempt < retryDelays.count, Self.isTransient(error), !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func sendOnce(_ method: String, _ path: String, envelope: SignedEnvelope?) async throws -> Data {
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
