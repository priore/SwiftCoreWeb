// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import UIKit

/// The name of the machine the app runs on, as people know it ("Anna's iPhone", "Mac mini").
enum DeviceLabel {
    @MainActor
    static var name: String {
        #if targetEnvironment(macCatalyst)
        // UIDevice reports "iPad" for a Catalyst app.
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #else
        return UIDevice.current.name
        #endif
    }
}
