// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Testing
import Foundation
import WebKit
@testable import SwiftCoreWebKit
import SwiftCoreWeb

/// The pure parts of the helper. A real `WKWebView` download needs a device or
/// simulator UI session: see "Blob downloads in WKWebView" in the docs for the manual checklist.
@MainActor
struct BlobDownloadSupportTests {
    @Test func attachmentDetection() {
        #expect(BlobDownloadSupport.isAttachment("attachment; filename=\"a.pdf\""))
        #expect(BlobDownloadSupport.isAttachment("  Attachment"))
        #expect(!BlobDownloadSupport.isAttachment("inline; filename=\"a.pdf\""))
        #expect(!BlobDownloadSupport.isAttachment(nil))
    }

    @Test func fileNameSanitisation() {
        #expect(BlobDownloadSupport.sanitizedFileName("../../etc/passwd") == "passwd")
        #expect(BlobDownloadSupport.sanitizedFileName("a\r\nb.txt") == "ab.txt")
        #expect(BlobDownloadSupport.sanitizedFileName("..") == "download")
        #expect(BlobDownloadSupport.sanitizedFileName("") == "download")
        #expect(BlobDownloadSupport.sanitizedFileName("relazione è.pdf") == "relazione è.pdf")
    }

    @Test func policyMapping() {
        #expect(BlobDownloadSupport.responsePolicy(contentDisposition: "attachment", canShowMIMEType: true) == .download)
        #expect(BlobDownloadSupport.responsePolicy(contentDisposition: nil, canShowMIMEType: false) == .download)
        #expect(BlobDownloadSupport.responsePolicy(contentDisposition: nil, canShowMIMEType: true) == .allow)
        let http = URL(string: "http://127.0.0.1:8080/x")
        #expect(BlobDownloadSupport.actionPolicy(shouldPerformDownload: true, url: http) == .download)
        #expect(BlobDownloadSupport.actionPolicy(shouldPerformDownload: false, url: http) == .allow)
        #expect(BlobDownloadSupport.actionPolicy(shouldPerformDownload: true, url: URL(string: "blob:http://127.0.0.1:8080/1")) == .allow)
    }

    @Test func installSetsUserAgentTokenAndScriptOnce() {
        let configuration = WKWebViewConfiguration()
        BlobDownloadSupport.install(on: configuration)
        BlobDownloadSupport.install(on: configuration, userScript: false)
        #expect(configuration.applicationNameForUserAgent?.components(separatedBy: "SwiftCoreWebHost/1").count == 2, "token added once")
        #expect(configuration.userContentController.userScripts.count == 1)
        #expect(configuration.userContentController.userScripts[0].source == BlobDownloadShim.source)

        let bare = WKWebViewConfiguration()
        BlobDownloadSupport.install(on: bare, userAgentToken: false, userScript: false)
        #expect(bare.userContentController.userScripts.isEmpty)
    }
}
