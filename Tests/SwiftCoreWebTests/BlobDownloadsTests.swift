// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Testing
import Foundation
import JavaScriptCore
import SwiftCoreWebTesting
@testable import SwiftCoreWeb

private struct ShellPage: Page {
    static let template = "shell.html"
}

struct BlobDownloadsTests {
    private let nativeUA = [("User-Agent", "Mozilla/5.0 SwiftCoreWebHost/1")]

    // MARK: C1 — endpoints (API-only app: no useVue/usePages/useSession/useSpa)

    @Test func blobRoundTripServesIdenticalBytesOnceAsAttachment() async throws {
        let app = WebApplication.createBuilder().build()
        app.useBlobDownloads()
        let host = try await TestHost(app)
        let bytes = TransferSupport.randomBytes(1_000_000)

        let upload = try await host.post("/_framework/blob", body: bytes, headers: [
            ("X-SCW-Blob", "1"), ("X-SCW-Filename", "relazione%20%C3%A8.pdf"), ("Content-Type", "application/pdf")
        ])
        #expect(upload.status == 200)
        let url = try #require(try upload.decode([String: String].self)["url"])
        #expect(url.hasPrefix("/_framework/dl/"))
        let af = try #require(TransferSupport.cookie("__scw_af", in: upload))

        let download = try await host.get(url, headers: [("Cookie", "__scw_af=\(af)")])
        #expect(download.status == 200)
        #expect(download.body == bytes)
        #expect(download.headers["Content-Type"] == "application/pdf")
        #expect(download.headers["Content-Disposition"] == "attachment; filename=\"relazione _.pdf\"; filename*=UTF-8''relazione%20%C3%A8.pdf")
        #expect(download.headers["Cache-Control"] == "no-store")
        #expect(download.headers["X-Content-Type-Options"] == "nosniff")

        #expect(try await host.get(url, headers: [("Cookie", "__scw_af=\(af)")]).status == 404)
    }

    @Test func blobRejectsMissingHeaderOversizeAndOtherOwner() async throws {
        let app = WebApplication.createBuilder().build()
        app.useBlobDownloads(maxBytes: 1000)
        let host = try await TestHost(app)

        #expect(try await host.post("/_framework/blob", body: Data(count: 10)).status == 403)
        #expect(try await host.post("/_framework/blob", body: Data(count: 1001), headers: [("X-SCW-Blob", "1")]).status == 413)

        let upload = try await host.post("/_framework/blob", body: Data(count: 10), headers: [("X-SCW-Blob", "1"), ("Cookie", "__scw_af=owner")])
        let url = try #require(try upload.decode([String: String].self)["url"])
        #expect(TransferSupport.cookie("__scw_af", in: upload) == nil, "an existing cookie is reused, not re-minted")
        #expect(try await host.get(url).status == 404)
        #expect(try await host.get(url, headers: [("Cookie", "__scw_af=intruder")]).status == 404)
        #expect(try await host.get(url, headers: [("Cookie", "__scw_af=owner")]).status == 200, "a wrong owner does not consume the token")
    }

    @Test func storeBoundsEntriesBytesAndLifetime() {
        let store = OneTimeDownloadStore(maxTotalBytes: 100, maxEntries: 2, ttl: 60)
        let request = HttpRequest(method: .get, path: "/", headers: HttpHeaders([("Cookie", "__scw_af=a")]))
        let owner = DownloadOwner(antiforgery: "a", request: request)
        func response(_ size: Int) -> HttpResponse { Results.data(Data(count: size)).response }
        let start = Date()

        #expect(store.put(response(101), owner: owner, now: start) == nil, "bigger than the whole store")
        let first = store.put(response(40), owner: owner, now: start)
        _ = store.put(response(40), owner: owner, now: start)
        _ = store.put(response(40), owner: owner, now: start) // evicts the oldest: count and bytes caps
        #expect(store.count == 2)
        #expect(store.take(first!, request: request, now: start) == nil)

        let kept = store.put(response(10), owner: owner, now: start)!
        #expect(store.take(kept, request: request, now: start.addingTimeInterval(61)) == nil, "expired")
        #expect(store.count == 0)
    }

    @Test func htmlDownloadsAreNeverRewrittenByInjection() async throws {
        let app = WebApplication.createBuilder().build()
        app.useBlobDownloads()
        let host = try await TestHost(app)
        let html = Data("<html><head></head><body>report</body></html>".utf8)

        let upload = try await host.post("/_framework/blob", body: html, headers: [
            ("X-SCW-Blob", "1"), ("X-SCW-Filename", "report.html"), ("Content-Type", "text/html"), ("User-Agent", "SwiftCoreWebHost/1"), ("Cookie", "__scw_af=a")
        ])
        let url = try #require(try upload.decode([String: String].self)["url"])
        let download = try await host.get(url, headers: nativeUA + [("Cookie", "__scw_af=a")])

        #expect(download.body == html)
        #expect(download.headers["Cache-Control"] == "no-store")
    }

    // MARK: C2 — shim source

    @Test func servedShimEqualsPublicConstantAndUsesNoEval() async throws {
        let app = WebApplication.createBuilder().build()
        app.useBlobDownloads()
        let host = try await TestHost(app)
        let response = try await host.get("/_framework/blob-download.js")
        #expect(response.bodyString == BlobDownloadShim.source)
        #expect(response.headers["Content-Type"]?.hasPrefix("text/javascript") == true)
        #expect(!BlobDownloadShim.source.contains("eval("))
        #expect(!BlobDownloadShim.source.contains("new Function"))
    }

    /// The shim against a minimal DOM stub in JavaScriptCore (no WebKit).
    @Test func shimInterceptsOnlyBlobDownloadAnchorsAndLoadsOnce() throws {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS exception: \(String(describing: exception))") }
        context.evaluateScript("""
        var window = this, calls = [], listeners = {}, n = 0;
        function Blob(parts, options) { this.type = (options && options.type) || ''; }
        var URL = { createObjectURL: function () { return 'blob:test/' + (++n); }, revokeObjectURL: function () {} };
        function HTMLAnchorElement(href, download) { this.tagName = 'A'; this.href = href; this.download = download; this.style = {}; }
        HTMLAnchorElement.prototype.hasAttribute = function (name) { return name === 'download' && this.download !== undefined; };
        HTMLAnchorElement.prototype.getAttribute = function (name) { return name === 'download' ? this.download : null; };
        HTMLAnchorElement.prototype.click = function () { calls.push('click ' + this.href); };
        HTMLAnchorElement.prototype.dispatchEvent = function () { calls.push('dispatch ' + this.href); return true; };
        HTMLAnchorElement.prototype.remove = function () {};
        var document = {
          body: { appendChild: function () {} },
          createElement: function () { return new HTMLAnchorElement('', ''); },
          addEventListener: function (type, fn) { listeners[type] = (listeners[type] || []).concat(fn); },
          dispatchEvent: function (event) { calls.push('event ' + event.type); }
        };
        function CustomEvent(type, init) { this.type = type; this.detail = init && init.detail; }
        var setTimeout = function () {};
        var fetch = function (url, init) {
          calls.push('fetch ' + init.method + ' ' + url + ' ' + init.headers['X-SCW-Blob'] + ' ' + init.headers['X-SCW-Filename'] + ' ' + init.headers['Content-Type']);
          return Promise.resolve({ ok: true, json: function () { return Promise.resolve({ url: '/_framework/dl/token' }); } });
        };
        """)
        context.evaluateScript(BlobDownloadShim.source)
        context.evaluateScript(BlobDownloadShim.source) // idempotent: a second load must not double-patch
        context.evaluateScript("""
        var blob = new Blob(['x'], { type: 'application/pdf' });
        var url = URL.createObjectURL(blob);
        var detached = new HTMLAnchorElement(url, 'relazione è.pdf');
        detached.click();
        URL.revokeObjectURL(url);                       // pages revoke right after click()
        new HTMLAnchorElement('/plain', 'x').click();   // http href with download: untouched
        new HTMLAnchorElement(url, undefined).click();  // blob href without download: untouched
        """)
        // Promise jobs run once the evaluating script returns; a no-op script flushes any left.
        context.evaluateScript("0")

        let calls = context.objectForKeyedSubscript("calls").toArray() as? [String] ?? []
        // Plain anchors click through synchronously; the blob anchor is uploaded once, then one navigation.
        #expect(calls == [
            "click /plain",
            "click blob:test/1",
            "fetch POST /_framework/blob 1 relazione%20%C3%A8.pdf application/pdf",
            "click /_framework/dl/token",
        ], "\(calls)")

        let clickListeners = context.evaluateScript("listeners.click.length")?.toInt32() ?? 0
        #expect(clickListeners == 1, "double load registered the capture listener once")
    }

    // MARK: C3 — injection

    private func makeSite(mode: BlobShimInjection?, spa: Bool = true) throws -> (WebApplication, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let page = "<!doctype html><html><head><title>t</title></head><body>hi</body></html>"
        try page.write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
        try page.write(toFile: dir + "/other.html", atomically: true, encoding: .utf8)
        try page.write(toFile: dir + "/zipped.html", atomically: true, encoding: .utf8)
        try Data([0x1f, 0x8b, 0, 1, 2]).write(to: URL(fileURLWithPath: dir + "/zipped.html.gz")) // sidecar; injection must read the plain sibling
        try String(repeating: "0123456789", count: 20).write(toFile: dir + "/app.js", atomically: true, encoding: .utf8)

        let app = WebApplication.createBuilder().build()
        // Registered after the file middleware on purpose: injection must still see their HTML.
        if spa { app.useSpa(root: .path(dir)) } else { app.useStaticFiles(root: .path(dir)) }
        if let mode { app.useBlobDownloads(injection: mode) }
        return (app, dir)
    }

    private let tag = "<script src=\"/_framework/blob-download.js\"></script>"

    @Test func tokenClientsGetExactlyOneTagOnSpaStaticAndShell() async throws {
        let (spa, _) = try makeSite(mode: .auto)
        let spaHost = try await TestHost(spa)
        let index = try await spaHost.get("/", headers: nativeUA + [("Accept", "text/html")])
        let deepLink = try await spaHost.get("/some/route", headers: nativeUA + [("Accept", "text/html")])
        for response in [index, deepLink] {
            let html = try #require(response.bodyString)
            #expect(html.components(separatedBy: tag).count == 2, "exactly one tag")
            #expect(html.range(of: tag)!.lowerBound < html.range(of: "</head>")!.lowerBound)
            #expect(response.headers["Content-Length"] == "\(response.body.count)")
            #expect(response.headers["ETag"] == nil)
        }
        let (files, _) = try makeSite(mode: .auto, spa: false)
        let other = try await TestHost(files).get("/other.html", headers: nativeUA)
        #expect(other.bodyString?.components(separatedBy: tag).count == 2)
        let zipped = try await TestHost(files).get("/zipped.html", headers: nativeUA + [("Accept-Encoding", "gzip")])
        #expect(zipped.headers["Content-Encoding"] == nil)
        #expect(zipped.bodyString?.components(separatedBy: tag).count == 2)
    }

    @Test func liveShellGetsOneTagWithTokenAndIsByteIdenticalWithout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "<p>x</p>".write(toFile: dir + "/shell.html", atomically: true, encoding: .utf8)
        func makeApp(injecting: Bool) -> WebApplication {
            let app = WebApplication.createBuilder().build()
            app.usePages(root: .path(dir))
            app.mapPage("/shell", ShellPage.self)
            if injecting { app.useBlobDownloads(injection: .auto) }
            return app
        }
        let cookie = [("Cookie", "__scw_af=fixed")] // an existing cookie: nothing random is minted
        let injecting = try await TestHost(makeApp(injecting: true)), plain = try await TestHost(makeApp(injecting: false))

        let withToken = try await injecting.get("/shell", headers: cookie + nativeUA)
        #expect(withToken.bodyString?.components(separatedBy: tag).count == 2)
        #expect(withToken.headers["Content-Length"] == "\(withToken.body.count)")

        // The signed snapshot differs between apps (per-process key), so compare the shell around it.
        let a = try await injecting.get("/shell", headers: cookie), b = try await plain.get("/shell", headers: cookie)
        func stripSnapshot(_ r: TestResponse) -> String {
            (r.bodyString ?? "").replacingOccurrences(of: #"<script type="application/json" id="__live">.*?</script>"#, with: "", options: .regularExpression)
        }
        #expect(!(a.bodyString ?? "").contains(tag))
        #expect(stripSnapshot(a) == stripSnapshot(b))
        #expect(a.headers.all.map(\.name) == b.headers.all.map(\.name))
    }

    @Test func autoWithoutTokenIsByteIdenticalToNoInjection() async throws {
        let (plain, dir) = try makeSite(mode: nil)
        let injecting = WebApplication.createBuilder().build()
        injecting.useSpa(root: .path(dir))
        injecting.useBlobDownloads(injection: .auto)
        let a = try await TestHost(plain), b = try await TestHost(injecting)
        for path in ["/", "/other.html", "/app.js"] {
            let expected = try await a.get(path)
            let actual = try await b.get(path)
            #expect(actual.body == expected.body)
            #expect(actual.headers.all.map { "\($0.name)=\($0.value)" } == expected.headers.all.map { "\($0.name)=\($0.value)" })
        }
    }

    @Test func alwaysAndNeverAndNonHtmlAndRange() async throws {
        let always = try await TestHost(makeSite(mode: .always).0)
        #expect(try await always.get("/other.html").bodyString?.contains(tag) == true)
        #expect(try await always.get("/app.js").bodyString?.contains(tag) == false)

        let never = try await TestHost(makeSite(mode: .never).0)
        #expect(try await never.get("/other.html", headers: nativeUA).bodyString?.contains(tag) == false)
        #expect(try await never.get("/_framework/blob-download.js").status == 200)

        let auto = try await TestHost(makeSite(mode: .auto).0)
        let js = try await auto.get("/app.js", headers: nativeUA + [("Range", "bytes=0-9")])
        #expect(js.status == 206)
        #expect(js.headers["Content-Range"] == "bytes 0-9/200")
        #expect(js.bodyString == "0123456789")
    }
}
