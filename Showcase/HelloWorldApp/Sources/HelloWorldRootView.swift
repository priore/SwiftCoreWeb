// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI
import WebKit
import SwiftCoreWeb

/// Hosts a `WKWebView` pointed at the server started by
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
            if isServerRunning {
                HelloWorldWebView(url: URL(string: "http://127.0.0.1:8080/")!)
                    .ignoresSafeArea()
            } else if let startupError {
                Text(startupError).padding()
            } else {
                ProgressView("Starting SwiftCoreWeb…")
            }
        }
        .task {
            await startServer()
        }
        .onChange(of: scenePhase) { newPhase in
            Task { await handleScenePhaseChange(newPhase) }
        }
    }

    private func startServer() async {
        Task.detached {
            try? await app.runAsync()
        }
        while !app.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        isServerRunning = true
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        switch phase {
        case .background:
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

/// A `WKWebView` hosting the site served on this same device.
struct HelloWorldWebView: SwiftUI.UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
