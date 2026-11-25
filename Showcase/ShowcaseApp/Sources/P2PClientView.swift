// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import UIKit
import SwiftCoreWeb
import SwiftCoreWebP2P

/// The client side: pairs with a host from a `scw-p2p://` link (scan the host's QR code with the Camera app, which opens
/// this app) and calls the host's routes through the tunnel. The route used and the timings stay on screen, because with
/// the cable unplugged there is no console.
struct P2PClientView: SwiftUI.View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("p2pHostFingerprint") private var fingerprint = ""
    @AppStorage("p2pHostName") private var hostName = ""
    /// The same short key the host's list shows for this device: it tells the host's owner which entry to revoke.
    @AppStorage("p2pDeviceKey") private var deviceKey = ""
    /// How this device shows up in the host's list of paired devices; empty uses the system's name.
    @AppStorage("p2pDeviceName") private var deviceName = ""
    @State private var link = ""
    @State private var connection: SCWPeerConnection?
    @State private var base: URL?
    @State private var log: [String] = []
    @State private var busy = false
    @State private var suggestedName = ""

    var body: some SwiftUI.View {
        Form {
            Section("Pairing") {
                TextField("This device's name", text: $deviceName, prompt: Text(suggestedName))
                TextField("scw-p2p://… (or scan the host's QR code with Camera)", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Pair") { Task { await pair() } }.disabled(busy || PairingPayload(link) == nil)
                if !fingerprint.isEmpty {
                    Text("Paired host: \(hostName.isEmpty ? "unnamed" : hostName) (key \(TunnelFingerprint.short(fingerprint)))")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !deviceKey.isEmpty {
                        Text("This device's key: \(deviceKey)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Connection") {
                Button(connection == nil ? "Connect" : "Reconnect") { Task { await connect() } }
                    .disabled(busy || fingerprint.isEmpty)
                Button("Call /whoami and /api/users") { Task { await call() } }.disabled(busy || base == nil)
                Button("Disconnect", role: .destructive) { Task { await disconnect() } }.disabled(connection == nil)
            }
            Section("Log") {
                ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.footnote, design: .monospaced))
                }
            }
        }
        .task { suggestedName = await SCWPeerConnection.defaultDeviceName() }
        .onAppear(perform: takePendingLink)
        .onChange(of: model.pairingLink) { _ in takePendingLink() }
        .onDisappear { Task { await connection?.stop() } }
    }

    /// A link opened by the system (Camera app) while this screen is already showing arrives the same way.
    private func takePendingLink() {
        if let pending = model.pairingLink { link = pending; model.pairingLink = nil }
    }

    private func pair() async {
        guard let payload = PairingPayload(link) else { return }
        busy = true; defer { busy = false }
        let started = Date()
        do {
            await connection?.stop()
            connection = nil
            base = nil
            let peer = try await SCWPeerConnection.pair(payload, deviceName: deviceName.isEmpty ? nil : deviceName)
            fingerprint = peer.hostFingerprint
            deviceKey = TunnelFingerprint.short(peer.deviceFingerprint)
            hostName = peer.name ?? ""
            connection = peer
            note("paired in \(elapsed(started)) s")
        } catch { note("pairing failed: \(error)") }
    }

    private func connect() async {
        busy = true; defer { busy = false }
        let started = Date()
        do {
            let peer = try connection ?? SCWPeerConnection(hostFingerprint: fingerprint)
            connection = peer
            deviceKey = TunnelFingerprint.short(peer.deviceFingerprint)
            base = try await peer.start()
            note("connected in \(elapsed(started)) s, route \(routeName(peer.currentRoute))")
        } catch { note("connect failed after \(elapsed(started)) s: \(error)") }
    }

    private func call() async {
        guard let base, let connection else { return }
        busy = true; defer { busy = false }
        for path in ["whoami", "api/users"] {
            let started = Date()
            do {
                let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                note("GET /\(path) \(code) in \(elapsed(started)) s via \(routeName(connection.currentRoute)): \(String(decoding: data.prefix(120), as: UTF8.self))")
            } catch { note("GET /\(path) failed: \(error.localizedDescription)") }
        }
    }

    private func disconnect() async {
        await connection?.stop()
        connection = nil
        base = nil
        note("disconnected")
    }

    private func note(_ text: String) { log.insert(text, at: 0) }
    private func elapsed(_ since: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(since)) }
    private func routeName(_ route: PeerRoute?) -> String {
        switch route {
        case .local?: "local"
        case .discovered?: "discovered (Bonjour)"
        case .direct?: "direct (hole punching)"
        case .relay?: "relay (TURN)"
        case nil: "none"
        }
    }
}
