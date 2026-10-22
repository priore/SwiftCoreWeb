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

struct BinaryTransferTests {
    // MARK: A1, A6, A7 — API-only app, no Vue/Pages/Session

    @Test func multipartRoundTripOf5MBBinaryEchoedWithBothDispositionForms() async throws {
        let app = WebApplication.createBuilder().build()
        app.mapGroup("/files").maxRequestBodySize(10_000_000).mapPost("/echo") { ctx in
            let file = try bindForm(ctx).files[0]
            return Results.data(try file.data(), contentType: file.contentType ?? "application/octet-stream", fileName: "relazione è.pdf")
        }
        let host = try await TestHost(app)
        let bytes = TransferSupport.randomBytes(5_000_000)
        let (body, contentType) = TransferSupport.multipart(files: [("f", "in.pdf", "application/pdf", bytes)])

        let response = try await host.post("/files/echo", body: body, headers: [("Content-Type", contentType)])

        #expect(response.status == 200)
        #expect(response.body == bytes)
        let disposition = try #require(response.headers["Content-Disposition"])
        #expect(disposition == "attachment; filename=\"relazione _.pdf\"; filename*=UTF-8''relazione%20%C3%A8.pdf")
    }

    @Test func rawOctetStreamBodyReachesHandlerIntact() async throws {
        let app = WebApplication.createBuilder().build()
        app.mapGroup("/raw").maxRequestBodySize(4_000_000).mapPost("/echo") { ctx in
            Results.data(ctx.request.body, contentType: ctx.request.headers["Content-Type"] ?? "")
        }
        let host = try await TestHost(app)
        let bytes = TransferSupport.randomBytes(3_000_000)

        let response = try await host.post("/raw/echo", body: bytes, headers: [("Content-Type", "application/octet-stream")])

        #expect(response.body == bytes)
        #expect(response.headers["Content-Type"] == "application/octet-stream")
    }

    @Test func uploadedFileMoveSurvivesCleanupAndUnmovedIsDeleted() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let unmoved = Box("")
        let app = WebApplication.createBuilder().build()
        app.mapPost("/move") { ctx in
            let file = try bindForm(ctx).files[0]
            try file.move(to: destination)
            return "moved"
        }
        app.mapPost("/keep") { ctx in
            unmoved.value = try bindForm(ctx).files[0].temporaryPath
            return "kept"
        }
        let host = try await TestHost(app)
        let (body, contentType) = TransferSupport.multipart(files: [("f", "a.bin", "application/octet-stream", Data([0, 255, 1]))])

        _ = try await host.post("/move", body: body, headers: [("Content-Type", contentType)])
        _ = try await host.post("/keep", body: body, headers: [("Content-Type", contentType)])

        #expect(try Data(contentsOf: destination) == Data([0, 255, 1]))
        #expect(!unmoved.value.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: unmoved.value))
        #expect(UUID(uuidString: URL(fileURLWithPath: unmoved.value).lastPathComponent) != nil)
    }

    @Test func fileNamesCannotInjectHeadersOrPaths() {
        let header = contentDispositionHeader(fileName: "evil\"\r\nSet-Cookie: x=1/../../c\".txt")
        #expect(!header.contains("\r") && !header.contains("\n"))
        #expect(header.filter { $0 == "\"" }.count == 2, "only the quotes around the ASCII fallback")
        #expect(header.contains("filename=\"c_.txt\""))
        #expect(header.hasSuffix("filename*=UTF-8''c%22.txt"))
        #expect(contentDispositionHeader(fileName: "../..") == contentDispositionHeader(fileName: "download"))
        #expect(contentDispositionHeader(fileName: "a.txt", disposition: .inline).hasPrefix("inline;"))
    }

    // MARK: A5 — per-route body limit

    @Test func perRouteLimitOverridesGlobalOnlyForItsRoutes() async throws {
        let app = WebApplication.createBuilder().build() // global: 1 MB
        app.mapGroup("/big").maxRequestBodySize(4_000_000).mapPost("/x") { ctx in "\(ctx.request.body.count)" }
        app.mapGroup("/small").maxRequestBodySize(10).mapPost("/x") { ctx in "\(ctx.request.body.count)" }
        app.mapPost("/global") { ctx in "\(ctx.request.body.count)" }
        let host = try await TestHost(app)
        let twoMB = Data(count: 2_000_000)

        #expect(try await host.post("/big/x", body: twoMB).status == 200)
        #expect(try await host.post("/big/x", body: Data(count: 4_000_001)).status == 413)
        #expect(try await host.post("/small/x", body: Data(count: 11)).status == 413)
        #expect(try await host.post("/small/x", body: Data(count: 10)).status == 200)
        #expect(try await host.post("/global", body: twoMB).status == 413)
        #expect(try await host.post("/global", body: Data(count: 1000)).status == 200)
    }

    // MARK: A3 — Range for any Results.file

    @Test func resultsFileHonoursRangeIfRangeAndHead() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let content = TransferSupport.randomBytes(1000)
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let app = WebApplication.createBuilder().build()
        app.mapGet("/f") { _ in Results.file(path, contentType: "application/octet-stream", fileName: "f.bin") }
        let host = try await TestHost(app)

        let full = try await host.get("/f")
        #expect(full.status == 200 && full.body == content)
        #expect(full.headers["Accept-Ranges"] == "bytes")

        let partial = try await host.get("/f", headers: [("Range", "bytes=10-19")])
        #expect(partial.status == 206)
        #expect(partial.headers["Content-Range"] == "bytes 10-19/1000")
        #expect(partial.body == content.subdata(in: 10..<20))

        let suffix = try await host.get("/f", headers: [("Range", "bytes=-4")])
        #expect(suffix.status == 206 && suffix.body == content.suffix(4))

        let unsatisfiable = try await host.get("/f", headers: [("Range", "bytes=2000-")])
        #expect(unsatisfiable.status == 416)
        #expect(unsatisfiable.headers["Content-Range"] == "bytes */1000")

        let staleIfRange = try await host.get("/f", headers: [("Range", "bytes=0-1"), ("If-Range", "\"old\"")])
        #expect(staleIfRange.status == 200 && staleIfRange.body == content)

        let head = try await host.head("/f")
        #expect(head.status == 200 && head.body.isEmpty)
        #expect(head.headers["Content-Length"] == "1000")
        let headRange = try await host.head("/f", headers: [("Range", "bytes=0-9")])
        #expect(headRange.status == 206 && headRange.body.isEmpty && headRange.headers["Content-Length"] == "10")
    }

    // MARK: A2 — stream Content-Length

    @Test func resultsStreamContentLengthHeaderIsOptional() {
        let known = Results.stream(contentLength: 5, fileName: "a.txt") { _ in }
        let unknown = Results.stream { _ in }
        #expect(known.response.headers["Content-Length"] == "5")
        #expect(known.response.headers["Content-Disposition"] != nil)
        #expect(unknown.response.headers["Content-Length"] == nil)
    }

    // MARK: A2/A4/A5 on the real engine

    @Test func engineLoopbackKnownLengthStreamBigBinaryAndRouteLimit() async throws {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        let big = TransferSupport.randomBytes(12_000_000)
        app.mapGet("/big") { _ in Results.data(big) }
        let bigPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try big.write(to: URL(fileURLWithPath: bigPath))
        defer { try? FileManager.default.removeItem(atPath: bigPath) }
        app.mapGet("/bigfile") { _ in Results.file(bigPath) }
        app.mapGet("/bigstream") { _ in
            Results.stream { sink in
                for offset in stride(from: 0, to: big.count, by: 1_000_000) { try await sink.write(big.subdata(in: offset..<min(offset + 1_000_000, big.count))) }
            }
        }
        app.mapGet("/known") { _ in Results.stream(contentLength: 5) { sink in try await sink.write(Data("hello".utf8)) } }
        app.mapGet("/unknown") { _ in Results.stream { sink in try await sink.write(Data("hello".utf8)) } }
        app.mapGroup("/up").maxRequestBodySize(3_000_000).mapPost("/x") { ctx in "\(ctx.request.body.count)" }
        app.mapPost("/global") { ctx in "\(ctx.request.body.count)" }
        let server = Task { try await app.runAsync() }
        defer { server.cancel(); Task { try? await app.stopAsync() } }

        func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.httpBody = body
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        var started = false
        for _ in 0..<50 where !started {
            started = (try? await request("/known")) != nil
            if !started { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        #expect(started)

        let (bigData, _) = try await request("/big")
        #expect(bigData == big)
        #expect(try await request("/bigfile").0 == big)
        #expect(try await request("/bigstream").0 == big)
        let (_, known) = try await request("/known")
        #expect(known.expectedContentLength == 5)
        let (_, unknown) = try await request("/unknown")
        #expect(unknown.expectedContentLength == -1, "chunked")
        #expect(try await request("/up/x", method: "POST", body: Data(count: 2_000_000)).1.statusCode == 200)
        #expect(try await request("/global", method: "POST", body: Data(count: 2_000_000)).1.statusCode == 413)
    }
}
