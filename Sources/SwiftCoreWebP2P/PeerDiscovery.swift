// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import Network
import NIOConcurrencyHelpers

/// Finds a paired host on the local network again by the fingerprint it announces, so a changed address does not need a new
/// pairing. The announcement is only a hint: the connection still pins the host key, so a lookalike service gets nowhere.
enum PeerDiscovery {
    static let fingerprintKey = "fp"
    static let appPortKey = "sp"

    /// The IPv4 address and tunnel port of the host announcing `fingerprint`, or `nil` when none shows up within `timeout`.
    /// Addresses in `excluding` are skipped: they answered but were not the host (a lookalike announcing the same fingerprint).
    static func find(fingerprint: String, excluding: Set<String> = [], timeout: TimeInterval = 3) async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let state = NIOLockedValueBox<(done: Bool, probes: [NWConnection], seen: Set<NWEndpoint>)>((false, [], []))
            let queue = DispatchQueue(label: "SwiftCoreWebP2P.discovery", qos: .userInitiated)
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: P2PTunnelExtension.bonjourType, domain: nil), using: .tcp)

            @Sendable func finish(_ result: (host: String, port: Int)?) {
                let probes: [NWConnection]? = state.withLockedValue { value in
                    guard !value.done else { return nil }
                    value.done = true
                    return value.probes
                }
                guard let probes else { return }
                browser.cancel()
                probes.forEach { $0.cancel() }
                continuation.resume(returning: result)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let txt) = result.metadata, txt[fingerprintKey] == fingerprint else { continue }
                    // The browser reports the whole set on every change: probe each endpoint once. IPv4 only, like the pairing link.
                    let parameters = NWParameters.tcp
                    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                    let probe = NWConnection(to: result.endpoint, using: parameters)
                    let accepted = state.withLockedValue { value -> Bool in
                        guard !value.done, value.seen.insert(result.endpoint).inserted else { return false }
                        value.probes.append(probe)
                        return true
                    }
                    guard accepted else { return }
                    probe.stateUpdateHandler = { newState in
                        guard case .ready = newState,
                              case .hostPort(let host, let port)? = probe.currentPath?.remoteEndpoint,
                              case .ipv4(let address) = host else { return }
                        // `debugDescription` carries the interface as a suffix ("192.168.1.5%en0").
                        let text = address.debugDescription.split(separator: "%").first.map(String.init) ?? address.debugDescription
                        guard !excluding.contains(text) else { return }
                        finish((text, Int(port.rawValue)))
                    }
                    probe.start(queue: queue)
                }
            }
            browser.stateUpdateHandler = { if case .failed = $0 { finish(nil) } }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// The hosts announcing themselves on the local network (IPv4), after listening for `timeout` seconds.
    static func browse(timeout: TimeInterval = 3) async -> [DiscoveredHost] {
        await withCheckedContinuation { continuation in
            let state = NIOLockedValueBox<(done: Bool, probes: [NWConnection], seen: Set<NWEndpoint>, found: [DiscoveredHost])>((false, [], [], []))
            let queue = DispatchQueue(label: "SwiftCoreWebP2P.browse", qos: .userInitiated)
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: P2PTunnelExtension.bonjourType, domain: nil), using: .tcp)

            @Sendable func finish() {
                let outcome: (probes: [NWConnection], found: [DiscoveredHost])? = state.withLockedValue { value in
                    guard !value.done else { return nil }
                    value.done = true
                    return (value.probes, value.found)
                }
                guard let outcome else { return }
                browser.cancel()
                outcome.probes.forEach { $0.cancel() }
                continuation.resume(returning: outcome.found)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let txt) = result.metadata, let fingerprint = txt[fingerprintKey],
                          let appPort = txt[appPortKey].flatMap({ Int($0) }), case .service(let name, _, _, _) = result.endpoint else { continue }
                    let parameters = NWParameters.tcp
                    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                    let probe = NWConnection(to: result.endpoint, using: parameters)
                    let accepted = state.withLockedValue { value -> Bool in
                        guard !value.done, value.seen.insert(result.endpoint).inserted else { return false }
                        value.probes.append(probe)
                        return true
                    }
                    guard accepted else { continue }
                    probe.stateUpdateHandler = { newState in
                        guard case .ready = newState, case .hostPort(let host, let port)? = probe.currentPath?.remoteEndpoint, case .ipv4(let address) = host else { return }
                        let text = address.debugDescription.split(separator: "%").first.map(String.init) ?? address.debugDescription
                        state.withLockedValue { value in
                            guard !value.done, !value.found.contains(where: { $0.host == text && $0.fingerprint == fingerprint }) else { return }
                            value.found.append(DiscoveredHost(name: name, host: text, port: Int(port.rawValue), appPort: appPort, fingerprint: fingerprint))
                        }
                        probe.cancel()
                    }
                    probe.start(queue: queue)
                }
            }
            browser.stateUpdateHandler = { if case .failed = $0 { finish() } }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }
}
