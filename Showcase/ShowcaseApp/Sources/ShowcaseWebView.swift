// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Showcase sample. Not part of the SwiftCoreWeb library targets — see
// Showcase/README.md for how to wire these files into an Xcode app target.

import SwiftUI
import WebKit

/// A `WKWebView` hosting the site served by `ShowcaseServer.makeApplication()`
/// on the same device, same origin — no CORS needed (the SPA hosting design). Requires
/// `NSAllowsLocalNetworking = YES` in Info.plist; see `Showcase/Info.plist.snippet.xml`.
struct ShowcaseWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The URL never changes for this showcase; Vue Router handles
        // client-side navigation once the page loads (the SPA hosting design's history-mode
        // fallback keeps deep links working across a reload too).
    }
}
