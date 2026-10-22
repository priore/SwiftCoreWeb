// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Testing
import Foundation
import SwiftCoreWebTesting
@testable import SwiftCoreWeb

private let uploadedTempPaths = Box<[String]>([])

private struct TransferPage: Page {
    static let template = "transfer.html"
    static let maxUploadBytes: Int? = 200
    static let allowedUploadTypes: [String]? = ["text/plain", ".md"]
    static let maxUploadFiles: Int? = 2

    var received: [String] = []

    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction {
        switch event {
        case "export":
            return .download(data: Data([0, 255, 128, 10]), fileName: "dati è.bin", contentType: "application/octet-stream")
        case "upload":
            received = ctx.files.map { "\($0.fileName):\($0.sizeInBytes)" }
            uploadedTempPaths.value = ctx.files.map(\.temporaryPath)
        case "raw":
            return .result(Results.data(Data("raw".utf8), contentType: "text/plain"))
        case "go":
            return .result(Results.redirect("/elsewhere"))
        default: break
        }
        return .render
    }
}

@Suite(.serialized)
struct LiveTransferTests {
    private struct Payload: Decodable {
        let snapshot: String
        let checksum: String
        let redirect: String?
        let download: String?
    }

    private func makeApp() throws -> WebApplication {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "<p>x</p>".write(toFile: dir + "/transfer.html", atomically: true, encoding: .utf8)
        let app = WebApplication.createBuilder().build()
        app.usePages(root: .path(dir))
        app.mapPage("/transfer", TransferPage.self)
        app.mapPage("/other", TransferPage.self)
        return app
    }

    private func load(_ host: TestHost) async throws -> (payload: Payload, af: String) {
        let response = try await host.get("/transfer")
        let html = try #require(response.bodyString)
        let start = try #require(html.range(of: "id=\"__live\">")?.upperBound)
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound)
        return (try JSONDecoder().decode(Payload.self, from: Data(html[start..<end].utf8)), try #require(TransferSupport.cookie("__scw_af", in: response)))
    }

    private func jsonEvent(_ host: TestHost, _ event: String, _ payload: Payload, af: String) async throws -> TestResponse {
        struct Body: Encodable { let snapshot, checksum, event: String; let form: [String: String] }
        return try await host.post("/transfer", json: Body(snapshot: payload.snapshot, checksum: payload.checksum, event: event, form: [:]), headers: [("Cookie", "__scw_af=\(af)")])
    }

    // MARK: B1 / B2

    @Test func downloadEventRepliesWithOneTimeTokenUrlBoundToTheCookie() async throws {
        let app = try makeApp()
        let host = try await TestHost(app)
        let (payload, af) = try await load(host)

        let reply = try await jsonEvent(host, "export", payload, af: af)
        let url = try #require(try reply.decode(Payload.self).download)
        #expect(url.hasPrefix("/_framework/dl/"))

        #expect(try await host.get(url, headers: [("Cookie", "__scw_af=other")]).status == 404)
        let file = try await host.get(url, headers: [("Cookie", "__scw_af=\(af)")])
        #expect(file.body == Data([0, 255, 128, 10]))
        #expect(file.headers["Content-Disposition"]?.contains("filename*=UTF-8''dati%20%C3%A8.bin") == true)
        #expect(try await host.get(url, headers: [("Cookie", "__scw_af=\(af)")]).status == 404)

        // expired: a take past the TTL evicts it, so the route answers 404
        let second = try #require(try await jsonEvent(host, "export", payload, af: af).decode(Payload.self).download)
        let store = sharedOneTimeDownloadStoreBox.store(for: app) { OneTimeDownloadStore() }.store
        let request = HttpRequest(method: .get, path: second, headers: HttpHeaders([("Cookie", "__scw_af=\(af)")]))
        #expect(store.take(String(second.dropFirst("/_framework/dl/".count)), request: request, now: Date().addingTimeInterval(61)) == nil)
        #expect(try await host.get(second, headers: [("Cookie", "__scw_af=\(af)")]).status == 404)
    }

    @Test func rawResultBecomesDownloadAndRedirectResultRedirects() async throws {
        let host = try await TestHost(try makeApp())
        let (payload, af) = try await load(host)

        let raw = try await jsonEvent(host, "raw", payload, af: af).decode(Payload.self)
        #expect(raw.download != nil, "a non-JSON result is converted, never sent to the client's JSON parser")
        let redirect = try await jsonEvent(host, "go", payload, af: af).decode(Payload.self)
        #expect(redirect.redirect == "/elsewhere")
    }

    // MARK: B3 / B4

    private func upload(_ host: TestHost, path: String = "/transfer", payload: Payload, af: String, checksum: String? = nil, live: Bool = true, files: [(name: String, fileName: String, contentType: String, data: Data)]) async throws -> TestResponse {
        let (body, contentType) = TransferSupport.multipart(
            fields: [("snapshot", payload.snapshot), ("checksum", checksum ?? payload.checksum), ("event", "upload"), ("args", "[]"), ("form", "{}")],
            files: files
        )
        var headers = [("Content-Type", contentType), ("Cookie", "__scw_af=\(af)")]
        if live { headers.append(("X-SCW-Live", "1")) }
        return try await host.post(path, body: body, headers: headers)
    }

    @Test func multipartEventPopulatesFilesAndCleansUp() async throws {
        let host = try await TestHost(try makeApp())
        let (payload, af) = try await load(host)

        let response = try await upload(host, payload: payload, af: af, files: [("files", "note.md", "text/markdown", Data("# hi".utf8)), ("files", "a.txt", "text/plain", Data("abc".utf8))])

        #expect(response.status == 200)
        #expect(response.bodyString?.contains("note.md:4") == true)
        #expect(response.bodyString?.contains("a.txt:3") == true)
        #expect(uploadedTempPaths.value.count == 2)
        #expect(uploadedTempPaths.value.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func multipartEventRejectsTamperingWrongPathWrongCookieAndMissingHeader() async throws {
        let host = try await TestHost(try makeApp())
        let (payload, af) = try await load(host)
        let file = [(name: "files", fileName: "a.txt", contentType: "text/plain", data: Data("abc".utf8))]

        #expect(try await upload(host, payload: payload, af: af, checksum: String(repeating: "0", count: 64), files: file).status == 400)
        #expect(try await upload(host, path: "/other", payload: payload, af: af, files: file).status == 400)
        #expect(try await upload(host, payload: payload, af: "not-the-cookie", files: file).status == 400)
        #expect(try await upload(host, payload: payload, af: af, live: false, files: file).status == 403)
    }

    @Test func pageLimitsAnswer413AndContextErrors() async throws {
        let host = try await TestHost(try makeApp())
        let (payload, af) = try await load(host)

        let tooBig = try await upload(host, payload: payload, af: af, files: [("files", "a.txt", "text/plain", Data(count: 201))])
        #expect(tooBig.status == 413)

        let wrongType = try await upload(host, payload: payload, af: af, files: [("files", "a.png", "image/png", Data(count: 5))])
        #expect(wrongType.status == 200)
        #expect(wrongType.bodyString?.contains("File type not allowed") == true)

        let tooMany = try await upload(host, payload: payload, af: af, files: (0..<3).map { ("files", "\($0).txt", "text/plain", Data(count: 1)) })
        #expect(tooMany.bodyString?.contains("At most 2 file(s) allowed") == true)
    }
}
