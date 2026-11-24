// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOConcurrencyHelpers
import SwiftCoreWeb

/// The meeting point hosts and devices use when they are on different networks. Mount it on an SCW app that both can reach:
///
/// ```swift
/// let app = WebApplication.createBuilder().build()
/// P2PRendezvous().mount(on: app)
/// ```
///
/// It keeps, in memory and for a few minutes, the signed list of addresses each host published, and the "knocks" of devices
/// that want to reach a host. It never sees a payload of the app, a private key or a token: what it stores is signed by
/// the host or the device, so a reader can tell whether it was altered, and what it learns about a device is its public
/// address and key fingerprint. Run it behind TLS; the address it records is the one the connection came from, so behind a
/// reverse proxy that is the proxy's. It has no per-client limit of its own: put the app's `rateLimit` in front of it to
/// keep one address from filling `maxHosts` or crowding out the knocks of a host.
public final class P2PRendezvous: Sendable {
    private struct Stored {
        let envelope: SignedEnvelope
        let expires: Date
    }

    private struct State {
        var records: [String: Stored] = [:]
        var knocks: [String: [RendezvousKnock]] = [:]
    }

    private let maxHosts: Int
    private let recordLifetime: TimeInterval
    private let maxKnocksPerHost = 16
    private let maxClockSkew = 300
    private let state = NIOLockedValueBox(State())

    /// `maxHosts` bounds the memory a flood of registrations can take; a record is dropped `recordLifetime` seconds after
    /// its host last published it.
    public init(maxHosts: Int = 1000, recordLifetime: TimeInterval = 600) {
        self.maxHosts = maxHosts
        self.recordLifetime = recordLifetime
    }

    public func mount(on app: WebApplication) {
        app.mapPut("/p2p/v1/hosts/{host}", maxRequestBodySize: 8 * 1024) { [self] ctx in publish(ctx) }
        app.mapGet("/p2p/v1/hosts/{host}") { [self] ctx in lookup(ctx) }
        app.mapPost("/p2p/v1/hosts/{host}/knocks", maxRequestBodySize: 8 * 1024) { [self] ctx in knock(ctx) }
        app.mapPost("/p2p/v1/hosts/{host}/knocks/collect", maxRequestBodySize: 8 * 1024) { [self] ctx in collect(ctx) }
    }

    // MARK: - Routes

    private func publish(_ ctx: HttpContext) -> HttpResult {
        guard let (id, payload, signer, envelope) = signed(ctx), RendezvousPath.hostID(signer) == id,
              let record = try? JSONDecoder().decode(RendezvousRecord.self, from: payload), record.type == RendezvousPayloadType.record, record.fingerprint == signer,
              fresh(record.issued), record.candidates.count <= 8 else {
            return Results.problem(status: .badRequest, detail: "The record must be signed by the host it is for and be recent.")
        }
        let stored = state.withLockedValue { state -> Bool in
            state.records = state.records.filter { $0.value.expires > Date() }
            state.knocks = state.knocks.filter { state.records[$0.key] != nil } // knocks never outlive their host's record
            if state.records[id] == nil, state.records.count >= maxHosts { return false }
            state.records[id] = Stored(envelope: envelope, expires: Date().addingTimeInterval(recordLifetime))
            return true
        }
        return stored ? Results.noContent() : Results.problem(status: HttpStatusCode(503), detail: "The rendezvous is full.")
    }

    private func lookup(_ ctx: HttpContext) -> HttpResult {
        guard let id = ctx.request.routeValues["host"] else { return Results.notFound() }
        let found = state.withLockedValue { $0.records[id].flatMap { $0.expires > Date() ? $0.envelope : nil } }
        return found.map { Results.json($0) } ?? Results.notFound()
    }

    private func knock(_ ctx: HttpContext) -> HttpResult {
        guard let (id, payload, _, envelope) = signed(ctx),
              let request = try? JSONDecoder().decode(RendezvousKnockRequest.self, from: payload), request.type == RendezvousPayloadType.knock,
              RendezvousPath.hostID(request.hostFingerprint) == id, fresh(request.issued) else {
            return Results.problem(status: .badRequest, detail: "The knock must be signed, recent and for this host.")
        }
        let entry = RendezvousKnock(address: ctx.request.remoteAddress ?? "unknown", envelope: envelope)
        let accepted = state.withLockedValue { state -> Bool in
            guard let stored = state.records[id], stored.expires > Date() else { return false } // only hosts that registered can be knocked on
            var list = state.knocks[id, default: []].filter { $0.envelope.key != envelope.key }
            list.append(entry)
            state.knocks[id] = Array(list.suffix(maxKnocksPerHost))
            return true
        }
        return accepted ? Results.noContent() : Results.notFound()
    }

    private func collect(_ ctx: HttpContext) -> HttpResult {
        guard let (id, payload, signer, _) = signed(ctx), RendezvousPath.hostID(signer) == id,
              let poll = try? JSONDecoder().decode(RendezvousPoll.self, from: payload),
              poll.type == RendezvousPayloadType.poll, poll.hostFingerprint == signer, fresh(poll.issued) else {
            return Results.problem(status: .badRequest, detail: "Only the host can read its knocks, with a signed recent request.")
        }
        let knocks = state.withLockedValue { $0.knocks.removeValue(forKey: id) ?? [] }
        return Results.json(knocks)
    }

    // MARK: - Helpers

    /// The host id in the path, the signed payload, who signed it and the envelope; `nil` when the body is not a valid one.
    private func signed(_ ctx: HttpContext) -> (id: String, payload: Data, signer: String, envelope: SignedEnvelope)? {
        guard let id = ctx.request.routeValues["host"],
              let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: ctx.request.body),
              let (payload, signer) = envelope.verified() else { return nil }
        return (id, payload, signer, envelope)
    }

    private func fresh(_ issued: Int) -> Bool {
        abs(Int(Date().timeIntervalSince1970) - issued) <= maxClockSkew
    }
}
