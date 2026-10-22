// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import WebKit
import SwiftCoreWeb

/// Downloads for a `WKWebView` you own, by composition: create one, keep it, and
/// forward from your own `WKNavigationDelegate`. It never owns the web view or its navigation.
///
/// ```swift
/// let downloads = BlobDownloadSupport()
/// downloads.onFinished = { url in /* present your own save/share UI */ }
/// BlobDownloadSupport.install(on: configuration)   // UA token + blob: shim
///
/// func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
///     downloads.navigationActionPolicy(for: action)
/// }
/// func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
///     downloads.navigationResponsePolicy(for: response)
/// }
/// func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.adopt(download) }
/// func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.adopt(download) }
/// ```
@available(macOS 11.3, iOS 14.5, *)
@MainActor
public final class BlobDownloadSupport: NSObject, WKDownloadDelegate {
    /// The `User-Agent` token that makes `useBlobDownloads(injection: .auto)` inject the shim.
    public nonisolated static let userAgentToken = "SwiftCoreWebHost/1"

    /// Called with the finished file (a temporary file you own from now on: move or share it).
    public var onFinished: ((URL) -> Void)?
    public var onFailed: ((Error) -> Void)?

    private var temporaryFiles: [ObjectIdentifier: URL] = [:]

    public override init() { super.init() }

    /// Sets the UA token and adds the blob shim as a user script; each part can be switched off.
    public static func install(on configuration: WKWebViewConfiguration, userAgentToken: Bool = true, userScript: Bool = true) {
        if userAgentToken {
            let current = configuration.applicationNameForUserAgent ?? ""
            if !current.contains(Self.userAgentToken) {
                configuration.applicationNameForUserAgent = current.isEmpty ? Self.userAgentToken : "\(current) \(Self.userAgentToken)"
            }
        }
        if userScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: BlobDownloadShim.source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
    }

    // MARK: - Forwarding from your WKNavigationDelegate

    public func navigationResponsePolicy(for response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        return Self.responsePolicy(contentDisposition: disposition, canShowMIMEType: response.canShowMIMEType)
    }

    public func navigationActionPolicy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        Self.actionPolicy(shouldPerformDownload: action.shouldPerformDownload, url: action.request.url)
    }

    /// Call from `navigationAction:didBecome:` and `navigationResponse:didBecome:`.
    public func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    /// Deletes the temporary files of downloads that are still in flight.
    public func cleanUp() {
        temporaryFiles.values.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryFiles.removeAll()
    }

    // MARK: - Pure policy mapping (unit-tested)

    public nonisolated static func responsePolicy(contentDisposition: String?, canShowMIMEType: Bool) -> WKNavigationResponsePolicy {
        isAttachment(contentDisposition) || !canShowMIMEType ? .download : .allow
    }

    /// `<a download>` on an http(s) URL; `blob:` links are the shim's job, and are never downloaded natively.
    public nonisolated static func actionPolicy(shouldPerformDownload: Bool, url: URL?) -> WKNavigationActionPolicy {
        let scheme = url?.scheme?.lowercased()
        return shouldPerformDownload && (scheme == "http" || scheme == "https") ? .download : .allow
    }

    public nonisolated static func isAttachment(_ contentDisposition: String?) -> Bool {
        contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
    }

    /// Last path component only, no control characters, never empty.
    public nonisolated static func sanitizedFileName(_ name: String) -> String {
        let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "download" : cleaned
    }

    // MARK: - WKDownloadDelegate

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCoreWebKit-downloads")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(Self.sanitizedFileName(suggestedFilename))")
        temporaryFiles[ObjectIdentifier(download)] = destination
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        // Ownership of the file passes to `onFinished`.
        guard let url = temporaryFiles.removeValue(forKey: ObjectIdentifier(download)) else { return }
        onFinished?(url)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = temporaryFiles.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: url)
        }
        onFailed?(error)
    }
}
