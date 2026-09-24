// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// The two implemented dashboard looks (see the plan's UI mockups A/B).
/// Runtime-switchable, not a build-time choice — persisted in `UserDefaults`
/// so the pick survives a relaunch.
public enum DashboardStyle: String, CaseIterable, Sendable {
    case missionControl
    case nativeCards

    private static let defaultsKey = "SwiftCoreWebDashboard.style"

    public static var stored: DashboardStyle {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(DashboardStyle.init(rawValue:)) ?? .nativeCards
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
