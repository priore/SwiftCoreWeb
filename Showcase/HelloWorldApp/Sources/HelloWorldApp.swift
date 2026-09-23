// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Minimal runnable showcase: "Hello World" page (current date/time + device
// name) plus one JSON API endpoint, reachable at http://[device-ip]/ and
// http://[device-ip]/api/device-name. See Showcase/HelloWorldApp/README.md
// for how to wire this into an Xcode app target (or run `xcodegen generate`
// in this directory to build one automatically).

import SwiftUI
import SwiftCoreWeb

@main
struct HelloWorldApp: App {
    @UIApplicationDelegateAdaptor(HelloWorldAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HelloWorldRootView(app: appDelegate.webApplication)
        }
    }
}

/// Builds the `WebApplication` at process launch, before any SwiftUI view
/// exists, so the first view's `.task` can call `runAsync()` immediately.
final class HelloWorldAppDelegate: NSObject, UIApplicationDelegate {
    let webApplication = HelloWorldServer.makeApplication()
}
