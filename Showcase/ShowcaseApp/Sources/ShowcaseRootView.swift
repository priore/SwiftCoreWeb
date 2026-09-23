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

/// Hosts the `WKWebView` (`ShowcaseWebView`) and binds the server's lifecycle
/// to SwiftUI's `ScenePhase` (the concurrency/lifecycle/network watchdog design): starting on first appearance, stopping
/// gracefully when the scene backgrounds, and restarting when it returns to
/// `.active`. This is the ScenePhase-driven alternative the framework's
/// `bindToLifecycle()` documentation refers to — written here in the
/// showcase because SwiftUI's `ScenePhase` is a view-level concern, not
/// something the framework itself needs to depend on SwiftUI for.
struct ShowcaseRootView: View {
    let app: WebApplication

    @Environment(\.scenePhase) private var scenePhase
    @State private var isServerRunning = false
    @State private var startupError: String?

    var body: some View {
        Group {
            if isServerRunning {
                ShowcaseWebView(url: URL(string: "http://127.0.0.1:8080/")!)
                    .ignoresSafeArea()
            } else if let startupError {
                ContentUnavailableView("Server failed to start", systemSymbolName: "exclamationmark.triangle", description: Text(startupError))
            } else {
                ProgressView("Starting SwiftCoreWeb…")
            }
        }
        .task {
            await startServer()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { await handleScenePhaseChange(newPhase) }
        }
    }

    private func startServer() async {
        do {
            // `runAsync()` suspends for as long as the server runs, so it is
            // launched from a detached task rather than awaited directly —
            // `isRunning` flips to `true` as soon as the listener is bound.
            Task.detached {
                try? await app.runAsync()
            }
            while !app.isRunning {
                try await Task.sleep(for: .milliseconds(20))
            }
            isServerRunning = true
        } catch {
            startupError = String(describing: error)
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            // Graceful shutdown (the concurrency/lifecycle/network watchdog design): stop accepting connections and drain
            // in-flight requests before the scene is fully suspended.
            guard app.isRunning else { return }
            try? await app.stopAsync(timeout: 5)
            isServerRunning = false
        case .active:
            guard !app.isRunning else { return }
            await startServer()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

/// A tiny, deployment-target-agnostic stand-in for `ContentUnavailableView`
/// (iOS 17+) so this showcase keeps compiling conceptually against the
/// framework's iOS 15 minimum deployment target.
private struct ContentUnavailableView: View {
    let title: String
    let systemSymbolName: String
    let description: Text

    init(_ title: String, systemSymbolName: String, description: Text) {
        self.title = title
        self.systemSymbolName = systemSymbolName
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemSymbolName)
                .font(.largeTitle)
            Text(title).font(.headline)
            description.font(.subheadline).foregroundColor(.secondary)
        }
        .padding()
    }
}
