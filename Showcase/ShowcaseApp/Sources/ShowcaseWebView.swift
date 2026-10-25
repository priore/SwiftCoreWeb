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
import SwiftCoreWebKit

/// A `WKWebView` hosting the site served by `ShowcaseServer.makeApplication()`
/// on the same device, same origin — no CORS needed (the SPA hosting design). Requires
/// `NSAllowsLocalNetworking = YES` in Info.plist; see `Showcase/Info.plist.snippet.xml`.
///
/// The web view and its navigation delegate are this sample's own code;
/// `BlobDownloadSupport` is a plain helper the coordinator forwards to, so a page that does
/// `URL.createObjectURL(blob)` + `<a download>` or serves a `Content-Disposition: attachment`
/// link ends up in `onFinished` with a file on disk.
struct ShowcaseWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // UA token (`SwiftCoreWebHost/1`, makes `useBlobDownloads()` inject the shim) + the shim as a user script.
        BlobDownloadSupport.install(on: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The URL never changes for this showcase; Vue Router handles
        // client-side navigation once the page loads (the SPA hosting design's history-mode
        // fallback keeps deep links working across a reload too).
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let downloads = BlobDownloadSupport()

        override init() {
            super.init()
            downloads.onFinished = { fileURL in
                // The developer decides what "saved" means; here: the share sheet.
                let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                    .first?.present(sheet, animated: true)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            downloads.navigationActionPolicy(for: navigationAction)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            downloads.navigationResponsePolicy(for: navigationResponse)
        }

        /// `window.open(url)` does nothing in a WKWebView without this: load the request in the same view
        /// (the response policy above turns an attachment into a download) and open no new web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            downloads.adopt(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            downloads.adopt(download)
        }
    }
}
