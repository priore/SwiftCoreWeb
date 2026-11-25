// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The name a device gives itself when it pairs, so the host's list reads "Anna's iPhone" and not a code.
enum DeviceName {
    /// The system's name for this device. On iOS 16 and later the system returns only the model ("iPhone") unless the app has
    /// the user-assigned-device-name entitlement (Apple approves it on request). Without it, a short part of the vendor
    /// identifier is added ("iPhone 7F3A") so two devices of the same model can be told apart in the host's list; pass your
    /// own name to `SCWPeerConnection.pair` for something better.
    static func system() async -> String {
        #if targetEnvironment(macCatalyst)
        // UIDevice reports "iPad" for a Catalyst app; the Mac's own name is the host name without its ".local".
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #elseif canImport(UIKit)
        return await MainActor.run {
            let device = UIDevice.current
            guard device.name == device.model, let id = device.identifierForVendor?.uuidString else { return device.name }
            return "\(device.name) \(id.prefix(4))"
        }
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    /// A name as shown in a list: no control characters, one line, at most 40 characters; `nil` when nothing is left.
    static func cleaned(_ name: String?) -> String? {
        guard let name else { return nil }
        let line = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : String(line.prefix(40))
    }
}
