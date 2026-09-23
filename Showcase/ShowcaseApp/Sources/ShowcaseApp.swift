// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Showcase sample. Not part of the SwiftCoreWeb library targets — see
// Showcase/README.md for how to wire these files into an Xcode app target.

import SwiftUI
import SwiftCoreWeb

/// The showcase app's entry point: builds the `WebApplication` once, starts
/// it, and hosts the served site in a `WKWebView` (`ShowcaseWebView.swift`).
///
/// Lifecycle binding uses SwiftUI's `ScenePhase` directly in `ShowcaseRootView`
/// rather than `WebApplication.bindToLifecycle()` (the UIKit-notifications
/// variant defined in the framework): this is the "SwiftUI ScenePhase helper"
/// the framework's `LifecycleSupport.swift` documents as living in the
/// showcase, since the framework itself only ships the UIKit variant.
@main
struct ShowcaseApp: App {
    @UIApplicationDelegateAdaptor(ShowcaseAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ShowcaseRootView(app: appDelegate.webApplication)
        }
    }
}

/// Builds the `WebApplication` at process launch, before any SwiftUI view
/// exists, so the very first `ShowcaseRootView.onAppear` can call `runAsync()`
/// without racing app startup.
final class ShowcaseAppDelegate: NSObject, UIApplicationDelegate {
    let webApplication = ShowcaseServer.makeApplication()
}
