// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import SwiftCoreWeb

/// Starts a server when the screen appears, shows `content` once it listens, and stops it when the screen goes away or the
/// app moves to the background (it starts again when the app is active).
struct ServerGate<Value, Content: SwiftUI.View>: SwiftUI.View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    let key: String
    let make: @MainActor () throws -> (WebApplication, Value)
    @ViewBuilder let content: (WebApplication, Value) -> Content

    private enum Phase { case starting, running(WebApplication, Value), failed(String) }
    @State private var phase = Phase.starting
    /// Set when the app went to the background and stopped the server; only then does `.active` start it again
    /// (at launch the scene also becomes `.active`, and a second concurrent start would replace the first server).
    @State private var stoppedInBackground = false
    @State private var restart: Task<Void, Never>?

    var body: some SwiftUI.View {
        Group {
            switch phase {
            case .starting: ProgressView("Starting SwiftCoreWeb…")
            case .running(let app, let value): content(app, value)
            case .failed(let message): Text(message).foregroundColor(.red).padding()
            }
        }
        .task { await start() }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                if case .running = phase { stoppedInBackground = true; stop() }
            case .active:
                if stoppedInBackground { stoppedInBackground = false; restart = Task { await start() } }
            default: break
            }
        }
    }

    private func start() async {
        do {
            let (app, value) = try make()
            try await model.runner.start(key, app)
            // The screen left while the server was starting: nothing shows it any more, so release the port.
            guard !Task.isCancelled else { await model.runner.stop(key, ifApp: app); return }
            phase = .running(app, value)
        } catch {
            NSLog("Showcase: %@ failed to start: %@", key, String(describing: error))
            phase = .failed(String(describing: error))
        }
    }

    private func stop() {
        restart?.cancel()
        guard case .running(let app, _) = phase else { return }
        phase = .starting
        Task { await model.runner.stop(key, ifApp: app) }
    }
}

/// A `ServerGate` whose content is the served site in a web view.
struct WebDemoView: SwiftUI.View {
    let key: String
    let path: String
    let make: @MainActor () -> WebApplication

    var body: some SwiftUI.View {
        ServerGate(key: key, make: { (make(), ()) }) { _, _ in
            ShowcaseWebView(url: URL(string: "http://127.0.0.1:8080\(path)")!).ignoresSafeArea()
        }
    }
}
