// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

/// The host's pairing screen, in SwiftUI so it looks native on iPhone, iPad, Mac and Apple TV: a QR code for the device to
/// scan, the host's key fingerprint (to compare by eye), a countdown, and the devices already paired, each with a button to
/// revoke it. Show it when the user asks to add a device; the pairing session closes when the view goes away.
///
/// ```swift
/// P2PPairingView(host: p2p, name: "Living room")
/// ```
///
/// On Apple TV this is how a device is paired: the TV shows the code and the phone scans it.
@available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
public struct P2PPairingView: View {
    private let host: P2PHost
    private let name: String?
    private let address: String?
    private let lifetime: TimeInterval

    @State private var payload: PairingPayload?
    @State private var expires = Date.distantPast
    @State private var now = Date()
    @State private var devices: [PairedDevice] = []

    /// `address` is where the other device will connect; by default the first address `LocalAddresses.ipv4()` finds.
    public init(host: P2PHost, name: String? = nil, address: String? = nil, validFor lifetime: TimeInterval = 120) {
        self.host = host
        self.name = name
        self.address = address
        self.lifetime = lifetime
    }

    public var body: some View {
        VStack(spacing: 24) {
            if let payload, expires > now, let image = Self.qrImage(for: payload.link) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 360, maxHeight: 360)
                    .padding(16)
                    .background(Color.white) // a QR code needs a light margin to scan, also in dark mode
                Text("Scan with the other device. Valid for \(max(0, Int(expires.timeIntervalSince(now)))) s.")
                    .font(.headline)
                Text(Self.spaced(payload.token))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                Text("or type this code on a device without a camera")
                    .foregroundStyle(.secondary)
                Text("Host key  \(Self.shortFingerprint(payload.hostKeyFingerprint))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(host.isEnabled ? "The pairing code expired." : "Peer-to-peer access is not running.")
                    .font(.headline)
            }
            Button(payload == nil || expires <= now ? "Show a pairing code" : "New code") { open() }
                .disabled(!host.isEnabled)
            if !devices.isEmpty {
                Divider()
                Text("Paired devices").font(.title3)
                ForEach(devices) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        Button("Revoke") { revoke(device) }
                    }
                }
            }
        }
        .padding()
        .task {
            open()
            while !Task.isCancelled {
                now = Date()
                devices = host.pairing?.devices ?? []
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onDisappear { host.pairing?.closePairing() }
    }

    private func open() {
        let target = address ?? LocalAddresses.ipv4().first ?? "127.0.0.1"
        payload = host.openPairing(host: target, name: name, validFor: lifetime, shortCode: true)
        expires = Date().addingTimeInterval(lifetime)
        now = Date()
    }

    private func revoke(_ device: PairedDevice) {
        _ = try? host.pairing?.revoke(deviceID: device.id)
        devices = host.pairing?.devices ?? []
    }

    /// `SHA256:AbCd…` as its first 12 characters after the prefix, for a comparison by eye.
    /// `123456` as `123 456`.
    static func spaced(_ code: String) -> String {
        guard code.count == 6, code.allSatisfy(\.isNumber) else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    static func shortFingerprint(_ fingerprint: String) -> String { TunnelFingerprint.short(fingerprint) }

    private static let context = CIContext()

    static func qrImage(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
