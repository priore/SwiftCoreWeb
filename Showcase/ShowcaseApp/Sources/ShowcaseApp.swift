// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI

@main
struct ShowcaseApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MenuView()
                .environmentObject(model)
                // A scw-p2p:// link scanned with the Camera app opens the client screen.
                .onOpenURL { model.openPairingLink($0) }
        }
    }
}
