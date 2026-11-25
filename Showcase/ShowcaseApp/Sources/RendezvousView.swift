// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import SwiftCoreWeb
import SwiftCoreWebP2P

/// Runs a `P2PRendezvous` on port 9090 of this device, on every interface and without authentication: a demo, stop it when done. It keeps running when the screen is left, so the P2P host (8080) can
/// run beside it; stop it here. For devices on other networks it must be reachable from the internet (see Showcase/README.md).
struct RendezvousView: SwiftUI.View {
    @EnvironmentObject private var model: AppModel
    @State private var running = false
    @State private var error: String?
    /// On when a reverse proxy on this Mac (or an SSH tunnel from a server) sits in front: devices are then recorded under
    /// the address the proxy reports in `X-Forwarded-For`. Off when devices connect to this port directly.
    @AppStorage("rendezvousBehindProxy") private var behindProxy = false

    static let port = 9090

    var body: some SwiftUI.View {
        Form {
            Section {
                Toggle("Run rendezvous server", isOn: Binding(get: { running }, set: { toggle($0) }))
                Toggle("Behind a proxy or SSH tunnel", isOn: $behindProxy).disabled(running)
                if let error { Text(error).foregroundColor(.red) }
            }
            if running {
                Section("Reachable at") {
                    ForEach(LocalAddresses.ipv4(), id: \.self) { address in
                        Text("http://\(address):\(Self.port)").font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .onAppear { running = model.runner.isRunning("rendezvous") }
    }

    private func toggle(_ on: Bool) {
        error = nil
        Task {
            if on {
                do { try await model.runner.start("rendezvous", Self.makeApplication(trustForwardedFor: behindProxy)) } catch { self.error = error.localizedDescription }
            } else {
                await model.runner.stop("rendezvous")
            }
            running = model.runner.isRunning("rendezvous")
        }
    }

    static func makeApplication(trustForwardedFor: Bool) -> WebApplication {
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        builder.listenOnAllInterfaces()
        let app = builder.build()
        P2PRendezvous(trustForwardedFor: trustForwardedFor).mount(on: app)
        return app
    }
}
