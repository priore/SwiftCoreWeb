// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import UIKit
import SwiftCoreWeb
import SwiftCoreWebP2P

/// The host side: an app with a couple of routes, reachable by paired devices through the tunnel.
struct P2PHostView: SwiftUI.View {
    @EnvironmentObject private var model: AppModel

    var body: some SwiftUI.View {
        ServerGate(key: "web", make: { try P2PHostServer.make(remote: model.settings.remoteAccess()) }) { _, host in
            HostPairing(host: host, remoteConfigured: model.settings.remoteAccess() != nil, hostName: "Showcase on \(DeviceLabel.name)")
        }
    }
}

/// The tunnel starts a moment after the server reports itself running: the pairing screen waits for its port.
private struct HostPairing: SwiftUI.View {
    let host: P2PHost
    let remoteConfigured: Bool
    let hostName: String
    @State private var port: Int?
    @State private var failed = false
    /// The address in the QR code. A Mac often has several (Ethernet and Wi-Fi): the phone must be able to reach the one shown.
    @State private var address = LocalAddresses.ipv4().first ?? "127.0.0.1"

    var body: some SwiftUI.View {
        ScrollView {
            VStack(spacing: 12) {
                if let port {
                    Text(verbatim: "Tunnel on port \(port)").font(.headline)
                    Text(remoteConfigured ? "Reachable from other networks through the relay" : "Local network only (no remote access configured)")
                        .font(.footnote).foregroundStyle(.secondary)
                    let addresses = LocalAddresses.ipv4()
                    if addresses.count > 1 {
                        Picker("Address in the QR code", selection: $address) {
                            ForEach(addresses, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    P2PPairingView(host: host, name: hostName, address: address).id(address)
                } else if failed {
                    Text("The tunnel did not start.").foregroundColor(.red)
                } else {
                    ProgressView("Starting the tunnel…")
                }
            }
            .padding(.top)
        }
        .task {
            for _ in 0..<100 where host.tunnelPort == nil {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return } // the screen left
            }
            port = host.tunnelPort
            failed = port == nil
        }
    }
}

enum P2PHostServer {
    /// The name the host announces and shows beside its QR code: this device's own name, so the client's list says which host it is.
    @MainActor
    static func make(remote: P2PRemoteAccess?) throws -> (WebApplication, P2PHost) {
        let name = "Showcase on \(DeviceLabel.name)"
        let builder = WebApplication.createBuilder()
        builder.usePort(8080)
        let host = try builder.useP2P(name: name, remote: remote)
        let app = builder.build()
        // A paired device is its own client: remoteAddress reads `p2p:<fingerprint>`.
        app.mapGet("/whoami") { ctx in ctx.request.remoteAddress ?? "none" }
        app.mapGet("/api/users") { _ in ["Alice", "Bob"] }
        return (app, host)
    }
}
