// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI

/// Where the P2P host publishes itself for devices on other networks. Leave empty to stay on the local network.
struct SettingsView: SwiftUI.View {
    @EnvironmentObject private var model: AppModel

    var body: some SwiftUI.View {
        let settings = model.settings
        Form {
            Section("Rendezvous") {
                TextField("https://rendezvous.example.com", text: Binding(get: { settings.rendezvous }, set: { settings.rendezvous = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
            Section("TURN server (TCP allocations, RFC 6062)") {
                TextField("Host (IPv4 or A record)", text: Binding(get: { settings.turnHost }, set: { settings.turnHost = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: Binding(get: { settings.turnPort }, set: { settings.turnPort = $0 })).keyboardType(.numberPad)
                TextField("User", text: Binding(get: { settings.turnUser }, set: { settings.turnUser = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Shared secret (kept in the Keychain)", text: Binding(get: { settings.turnSecret }, set: { settings.turnSecret = $0 }))
                Text(settings.turnSecret.isEmpty ? "No secret yet." : settings.secretSaved ? "Secret saved in the Keychain (\(settings.turnSecret.count) characters)." : "The Keychain refused the secret: it is not saved.")
                    .font(.footnote).foregroundStyle(settings.turnSecret.isEmpty || settings.secretSaved ? Color.secondary : Color.red)
            }
            Section {
                Text("Applies the next time the P2P host screen is opened. Changes are saved as you type.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
    }
}
