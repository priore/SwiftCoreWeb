// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import SwiftCoreWeb
import SwiftCoreWebDashboard

/// Hosts the on-device dashboard for the server started by
/// `HelloWorldServer.makeApplication()`, binding the server's lifecycle to
/// SwiftUI's `ScenePhase`.
///
/// Spelled `SwiftUI.View` throughout: SwiftCoreWeb exports its own `View`
/// type (an HTML view result), which otherwise shadows SwiftUI's.
struct HelloWorldRootView: SwiftUI.View {
    let app: WebApplication

    @Environment(\.scenePhase) private var scenePhase
    @State private var isServerRunning = false
    @State private var startupError: String?

    var body: some SwiftUI.View {
        Group {
            // Server up and running: show the on-device dashboard full-screen.
            if isServerRunning {
                // No .ignoresSafeArea(): the style picker lives in a top
                // safeAreaInset, which would draw under the status bar otherwise.
                SwiftCoreWebDashboardView(app: app)
            } else {
                // First launch, still waiting for the server to come up.
                ProgressView("Starting SwiftCoreWeb…")
            }
        }
        // Startup error shown as a banner on top, instead of a separate screen,
        // so the dashboard is still visible underneath once the server does come up.
        .overlay(alignment: .top) {
            if let startupError {
                Text(startupError)
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.9), in: .rect)
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
        }
        .task {
            // Runs once when this view first appears.
            await startServer()
        }
        .onChange(of: scenePhase) { newPhase in
            // App moved to background/foreground/etc: react to it.
            Task { await handleScenePhaseChange(newPhase) }
        }
    }

    /// Starts the server in the background and waits until it reports itself running
    /// before switching the UI over to the dashboard.
    private func startServer() async {
        // Runs the server on its own task so it doesn't block the UI.
        Task.detached {
            do {
                try await app.runAsync()
            } catch {
                // Surface the failure as a banner instead of swallowing it.
                await MainActor.run { startupError = error.localizedDescription }
            }
        }
        // Poll until the server flips to running (startup is async, no callback for it).
        while !app.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        isServerRunning = true
    }

    /// Keeps the server's running state in sync with the app's lifecycle:
    /// stop it when the app goes to background, restart it when it comes back.
    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            // Nothing to do if the server is already stopped.
            guard app.isRunning else { return }
            try? await app.stopAsync(timeout: 5)
            isServerRunning = false
        case .active:
            // Nothing to do if the server never stopped.
            guard !app.isRunning else { return }
            await startServer()
        case .inactive:
            // Transient state (e.g. app switcher); no action needed.
            break
        @unknown default:
            break
        }
    }
}
