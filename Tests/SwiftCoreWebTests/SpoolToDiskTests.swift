// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//


import Testing
import Foundation
import CryptoKit
import SwiftCoreWebTesting
@testable import SwiftCoreWeb

private func sha256(of url: URL) throws -> String {
    var hash = SHA256()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hash.update(data: block) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A scratch uploads directory for one test; `UploadStorage.directory` points at it while `body` runs.
private func withUploadsDirectory<T: Sendable>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scw-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await UploadStorage.$directory.withValue(directory) { try await body(directory) }
}

private func files(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
}

@Controller("/ctl")
private struct SpoolController {
    @Post("/up", maxRequestBodySize: 2_000_000, spoolBodyToDisk: true)
    func up() -> String { "ok" }
}

private let spooledPageSeen = Box<(bodyFile: Bool, body: Int, files: [String])>((false, -1, []))

private struct BigUploadPage: Page {
    static let template = "big.html"
    static let maxUploadBytes: Int? = 9_000_000

    mutating func onEvent(_ event: String, _ ctx: PageContext) async throws -> PageAction {
        spooledPageSeen.value = (ctx.http.request.bodyFile != nil, ctx.http.request.body.count, ctx.files.map { "\($0.fileName):\($0.sizeInBytes)" })
        return .render
    }
}

struct SpoolToDiskTests {
    // MARK: Multipart file reader

    @Test func mixedFieldsAndFilesAreSplitFromDisk() async throws {
        try await withUploadsDirectory { directory in
            let app = WebApplication.createBuilder().build()
            app.mapPost("/up", maxRequestBodySize: 10_000_000, spoolBodyToDisk: true) { ctx in
                let form = try bindForm(ctx)
                return form.files.map { "\($0.fieldName)|\($0.fileName)|\($0.contentType ?? "-")|\($0.sizeInBytes)|\((try? Data(contentsOf: URL(fileURLWithPath: $0.temporaryPath)).count) ?? -1)" }
                    + form.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            }
            let host = try await TestHost(app)
            let first = TransferSupport.randomBytes(300_000)
            let second = Data("line1\r\nline2\r\n--notTheBoundary\r\n".utf8)
            let (body, contentType) = TransferSupport.multipart(
                fields: [("title", "Backup è"), ("note", "")],
                files: [("a", "a.bin", "application/octet-stream", first), ("b", "b.txt", "text/plain", second), ("c", "empty.bin", "application/octet-stream", Data())]
            )

            let response = try await host.post("/up", body: body, headers: [("Content-Type", contentType)])

            #expect(response.status == 200)
            let lines = try response.decode([String].self)
            #expect(lines == [
                "a|a.bin|application/octet-stream|300000|300000", "b|b.txt|text/plain|\(second.count)|\(second.count)", "c|empty.bin|application/octet-stream|0|0",
                "note=", "title=Backup è"
            ])
            #expect(files(in: directory).isEmpty, "bodyFile and the promoted parts are removed after the response")
        }
    }

    @Test func boundaryStraddlingABlockEdgeIsFoundAtEveryOffset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scw-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try UploadStorage.$directory.withValue(directory) {
            // Every block size (down to smaller than the delimiter) against content lengths that move the
            // delimiter across each possible position of a block, with `\r`, `-` and a near-boundary inside the data.
            for contentLength in 0..<40 {
                let content = Data((0..<contentLength).map { [UInt8(13), 45, 10, 88][$0 % 4] }) + Data("\r\n--Bn".utf8)
                let (body, contentType) = TransferSupport.multipart(boundary: "Bnd", fields: [("f", "v")], files: [("p", "p.bin", "x/y", content)])
                let source = directory.appendingPathComponent("src")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try body.write(to: source)
                let expected = try MultipartParser.parse(body, boundary: "Bnd")

                for blockSize in [1, 2, 3, 5, 7, 8, 13, 64, 4096] {
                    let form = try MultipartFileParser.parse(file: source, boundary: MultipartParser.boundary(in: contentType), blockSize: blockSize)
                    #expect(form.fields == ["f": "v"])
                    #expect(form.files.count == 1)
                    let stored = try Data(contentsOf: URL(fileURLWithPath: form.files[0].temporaryPath))
                    #expect(stored == expected[1].data, "content \(contentLength) block \(blockSize)")
                    for file in form.files { try FileManager.default.removeItem(atPath: file.temporaryPath) }
                }
            }
        }
    }

    @Test func malformedAndOversizedFieldBodiesFailCleanlyAndLeaveNoFiles() async throws {
        try await withUploadsDirectory { directory in
            let app = WebApplication.createBuilder().build()
            app.useExceptionHandler()
            app.mapPost("/up", maxRequestBodySize: 10_000_000, spoolBodyToDisk: true) { ctx in "\(try bindForm(ctx).files.count)" }
            let host = try await TestHost(app)
            let (good, contentType) = TransferSupport.multipart(files: [("f", "a.bin", "x/y", Data(count: 100))])

            let truncated = good.prefix(good.count - 12) // loses the closing delimiter
            #expect(try await host.post("/up", body: Data(truncated), headers: [("Content-Type", contentType)]).status == 400)
            #expect(try await host.post("/up", body: Data("garbage".utf8), headers: [("Content-Type", contentType)]).status == 400)

            let (bigField, bigType) = TransferSupport.multipart(fields: [("t", String(repeating: "x", count: 1_100_000))], files: [("f", "a.bin", "x/y", Data(count: 10))])
            #expect(try await host.post("/up", body: bigField, headers: [("Content-Type", bigType)]).status == 413)
            #expect(files(in: directory).isEmpty)
        }
    }

    // MARK: Routing and request shape

    @Test func spooledRouteGetsBodyFileAndBufferedRouteIsUnchanged() async throws {
        try await withUploadsDirectory { directory in
            let seen = Box<String>("")
            let destination = directory.appendingPathComponent("kept.bin")
            let app = WebApplication.createBuilder().build()
            app.mapGroup("/s").maxRequestBodySize(5_000_000).spoolBodyToDisk().mapPost("/raw") { ctx in
                let file = try #require(ctx.request.bodyFile)
                seen.value = "\(ctx.request.body.count)|\(try Data(contentsOf: file).count)"
                return "ok"
            }
            app.mapPost("/s/move", maxRequestBodySize: 5_000_000, spoolBodyToDisk: true) { ctx in
                try FileManager.default.moveItem(at: try #require(ctx.request.bodyFile), to: destination)
                return "moved"
            }
            app.mapPost("/b", maxRequestBodySize: 5_000_000) { ctx in "\(ctx.request.body.count)|\(ctx.request.bodyFile == nil)" }
            app.mapPost("/b-form") { ctx in "\(try bindForm(ctx).fields["a"] ?? "")" }
            let host = try await TestHost(app)
            let bytes = TransferSupport.randomBytes(1_000_000)

            #expect(try await host.post("/s/raw", body: bytes, headers: [("Content-Type", "application/octet-stream")]).bodyString == "ok")
            #expect(seen.value == "0|1000000")
            #expect(try await host.post("/b", body: bytes).bodyString == "1000000|true")
            #expect(try await host.post("/b-form", body: Data("a=1&b=2".utf8), headers: [("Content-Type", "application/x-www-form-urlencoded")]).bodyString == "1")

            #expect(try await host.post("/s/move", body: bytes).status == 200)
            #expect(try Data(contentsOf: destination) == bytes, "a handler can keep the spooled file by moving it")
            #expect(files(in: directory) == ["kept.bin"])

            // the limit still applies to the spooled body
            #expect(try await host.post("/s/raw", body: Data(count: 5_000_001)).status == 413)
            #expect(files(in: directory) == ["kept.bin"])
        }
    }

    @Test func everyRegistrationFormCarriesTheSpoolFlag() throws {
        let app = WebApplication.createBuilder().build()
        app.mapControllers(SpoolController.self)
        app.mapPost("/direct", spoolBodyToDisk: true) { _ in "x" }
        app.mapPut("/direct", spoolBodyToDisk: true) { (_: HttpContext) in }
        app.mapMethods([.patch], "/multi", spoolBodyToDisk: true) { _ in "x" }
        app.mapGroup("/g").spoolBodyToDisk().mapPost("/x") { _ in "x" }
        app.mapPost("/plain") { _ in "x" }
        let dispatcher = try app.makeDispatcher()

        #expect(dispatcher.bodyPlan(method: .post, path: "/ctl/up") == (2_000_000, true))
        #expect(dispatcher.bodyPlan(method: .post, path: "/direct").spool)
        #expect(dispatcher.bodyPlan(method: .put, path: "/direct").spool)
        #expect(dispatcher.bodyPlan(method: .patch, path: "/multi").spool)
        #expect(dispatcher.bodyPlan(method: .post, path: "/g/x").spool)
        #expect(!dispatcher.bodyPlan(method: .post, path: "/plain").spool)
        #expect(!dispatcher.bodyPlan(method: .post, path: "/nowhere").spool)
    }

    @Test func startupSweepRemovesOnlyStaleFiles() async throws {
        try await withUploadsDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stale = directory.appendingPathComponent("stale"), fresh = directory.appendingPathComponent("fresh")
            try Data([1]).write(to: stale)
            try Data([1]).write(to: fresh)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: stale.path)

            UploadStorage.sweepStale()

            #expect(files(in: directory) == ["fresh"])
        }
    }

    // MARK: Live Pages

    @Test func livePageWithBigUploadLimitSpoolsItsPostAndDiscardsPartsWhenVerificationFails() async throws {
        try await withUploadsDirectory { directory in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "<p>x</p>".write(to: root.appendingPathComponent("big.html"), atomically: true, encoding: .utf8)
            let app = WebApplication.createBuilder().build()
            app.usePages(root: .path(root.path))
            app.mapPage("/big", BigUploadPage.self)
            let host = try await TestHost(app)

            let page = try await host.get("/big")
            let html = try #require(page.bodyString)
            let start = try #require(html.range(of: "id=\"__live\">")?.upperBound)
            let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound)
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(html[start..<end].utf8)) as? [String: Any])
            let snapshot = try #require(payload["snapshot"] as? String), checksum = try #require(payload["checksum"] as? String)
            let af = try #require(TransferSupport.cookie("__scw_af", in: page))
            func post(checksum: String, extra: [(String, String)] = [("X-SCW-Live", "1")]) async throws -> TestResponse {
                let (body, contentType) = TransferSupport.multipart(
                    fields: [("snapshot", snapshot), ("checksum", checksum), ("event", "upload"), ("args", "[]"), ("form", "{}")],
                    files: [("files", "doc.bin", "application/octet-stream", TransferSupport.randomBytes(3_000_000))]
                )
                return try await host.post("/big", body: body, headers: [("Content-Type", contentType), ("Cookie", "__scw_af=\(af)")] + extra)
            }

            #expect(try await post(checksum: checksum).status == 200)
            #expect(spooledPageSeen.value.bodyFile && spooledPageSeen.value.body == 0)
            #expect(spooledPageSeen.value.files == ["doc.bin:3000000"])
            #expect(files(in: directory).isEmpty)

            #expect(try await post(checksum: String(repeating: "0", count: 64)).status == 400)
            #expect(try await post(checksum: checksum, extra: []).status == 403)
            #expect(files(in: directory).isEmpty, "promoted parts are discarded when the snapshot check fails")
        }
    }

    // MARK: Blob downloads

    @Test func blobAboveTheThresholdIsServedBackFromDiskAndTheFileIsGoneAfterTheSingleGet() async throws {
        try await withUploadsDirectory { directory in
            let app = WebApplication.createBuilder().build()
            app.useBlobDownloads(maxBytes: 64 * 1024 * 1024)
            let host = try await TestHost(app)
            let bytes = TransferSupport.randomBytes(9_000_000)

            let small = try await host.post("/_framework/blob", body: TransferSupport.randomBytes(1_000_000), headers: [("X-SCW-Blob", "1")])
            #expect(small.status == 200)
            #expect(files(in: directory).isEmpty, "with the default maxBytes a small blob is still handled in memory")

            let upload = try await host.post("/_framework/blob", body: bytes, headers: [("X-SCW-Blob", "1"), ("X-SCW-Filename", "b.bin"), ("Content-Type", "application/zip")])
            #expect(upload.status == 200)
            let url = try #require(try upload.decode([String: String].self)["url"])
            let cookie = [("Cookie", "__scw_af=\(try #require(TransferSupport.cookie("__scw_af", in: upload)))")]
            #expect(files(in: directory).count == 1, "only the 9 MB blob waits on disk, not in the store's memory")

            #expect(try await host.send(.head, url, headers: cookie).status == 200)
            #expect(files(in: directory).count == 1, "a HEAD does not consume it")
            let download = try await host.get(url, headers: cookie)
            #expect(download.body == bytes)
            #expect(download.headers["Content-Type"] == "application/zip")
            #expect(download.headers["Content-Disposition"]?.hasPrefix("attachment") == true)
            #expect(files(in: directory).isEmpty)
            #expect(try await host.get(url, headers: cookie).status == 404)

            #expect(try await host.post("/_framework/blob", body: Data(), headers: [("X-SCW-Blob", "1")]).status == 400)
            #expect(files(in: directory).isEmpty)
        }
    }

    @Test func diskBudgetEvictsOldestAndExpiredEntriesAndDeletesTheirFiles() async throws {
        try await withUploadsDirectory { directory in
            let store = OneTimeDownloadStore(maxDiskBytes: 100, maxDiskEntries: 2, ttl: 60)
            let owner = DownloadOwner(antiforgery: "af", request: HttpRequest(method: .get, path: "/"))
            func entry(_ size: Int) throws -> (HttpResponse, String) {
                let url = try UploadStorage.newFileURL()
                try Data(count: size).write(to: url)
                return (Results.file(url.path).response, url.path)
            }
            let now = Date()

            let (r1, p1) = try entry(40), (r2, p2) = try entry(40), (r3, p3) = try entry(40)
            let t1 = try #require(store.put(r1, owner: owner, ownedFile: p1, now: now))
            _ = try #require(store.put(r2, owner: owner, ownedFile: p2, now: now))
            #expect(store.put(r3, owner: owner, ownedFile: p3, now: now) != nil)
            #expect(!FileManager.default.fileExists(atPath: p1), "entry count limit evicts the oldest and deletes its file")
            #expect(store.take(t1, request: HttpRequest(method: .get, path: "/")) == nil)

            let (huge, pHuge) = try entry(101)
            #expect(store.put(huge, owner: owner, ownedFile: pHuge, now: now) == nil, "over the byte budget on its own: refused, the caller keeps the file")
            #expect(FileManager.default.fileExists(atPath: pHuge))

            let (r4, p4) = try entry(1)
            _ = store.put(r4, owner: owner, ownedFile: p4, now: now.addingTimeInterval(120)) // expires p2 and p3 first
            #expect(!FileManager.default.fileExists(atPath: p2) && !FileManager.default.fileExists(atPath: p3))
            #expect(FileManager.default.fileExists(atPath: p4))
        }
    }

    // MARK: Real engine (loopback)

    private func withServer<T: Sendable>(_ configure: (WebApplication) -> Void, _ body: (_ port: Int, _ engine: ServerEngine, _ app: WebApplication) async throws -> T) async throws -> T {
        let port = Int.random(in: 30_000..<60_000)
        let builder = WebApplication.createBuilder()
        builder.usePort(port)
        let app = builder.build()
        configure(app)
        let server = Task { try await app.runAsync() }
        defer { server.cancel(); Task { try? await app.stopAsync() } }
        var engine: ServerEngine?
        for _ in 0..<80 where engine == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            if app.isRunning, !app.urls.isEmpty { engine = app.engineBox.engine }
        }
        return try await body(port, try #require(engine), app)
    }

    private func send(_ port: Int, _ path: String, file: URL, contentType: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        let (data, response) = try await URLSession(configuration: configuration).upload(for: request, fromFile: file)
        return (data, response as! HTTPURLResponse)
    }

    @Test func a300MBMultipartUploadIsSpooledWithoutBufferingAndMatchesTheSourceHash() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("scw-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }

        // The multipart body is written block by block (never held whole), hashing the file part as it goes.
        let boundary = "Big\(UUID().uuidString.prefix(8))"
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let out = try FileHandle(forWritingTo: source)
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nnightly\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"backup\"; filename=\"b.sqlite\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        var hash = SHA256()
        let block = TransferSupport.randomBytes(1 << 20)
        let blocks = 300
        for index in 0..<blocks {
            var piece = block
            piece.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) })
            hash.update(data: piece)
            try out.write(contentsOf: piece)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()
        let expectedHash = hash.finalize().map { String(format: "%02x", $0) }.joined()

        try await withServer({ app in
            app.mapPost("/backup", maxRequestBodySize: 400 * 1024 * 1024, spoolBodyToDisk: true) { ctx in
                let form = try bindForm(ctx)
                let file = try #require(form.files.first)
                return ["sha": try sha256(of: URL(fileURLWithPath: file.temporaryPath)), "size": "\(file.sizeInBytes)", "note": form.fields["note"] ?? "", "bodyCount": "\(ctx.request.body.count)"]
            }
            app.mapPost("/buffered", maxRequestBodySize: 1_000_000) { ctx in "\(ctx.request.body.count)" }
        }) { port, engine, _ in
            let (data, response) = try await send(port, "/backup", file: source, contentType: "multipart/form-data; boundary=\(boundary)")

            #expect(response.statusCode == 200)
            let reply = try JSONDecoder().decode([String: String].self, from: data)
            #expect(reply["sha"] == expectedHash)
            #expect(reply["size"] == "\(blocks << 20)")
            #expect(reply["note"] == "nightly")
            #expect(reply["bodyCount"] == "0")
            #expect(engine.bufferedBodyBytes.withLockedValue { $0 } == 0, "not one byte of the upload was held in the body buffer")

            let small = FileManager.default.temporaryDirectory.appendingPathComponent("scw-small-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: small) }
            try Data(count: 5000).write(to: small)
            #expect(try await send(port, "/buffered", file: small, contentType: "application/octet-stream").0 == Data("5000".utf8))
            #expect(engine.bufferedBodyBytes.withLockedValue { $0 } == 5000, "the counter does see a buffered route")
        }
    }

    @Test func serverShutdownDeletesTheTemporaryFileOfAnUploadInProgress() async throws {
        let created = Box<[URL]>([])
        try await withServer({ app in
            app.mapPost("/up", maxRequestBodySize: 50_000_000, spoolBodyToDisk: true) { _ in "never" }
        }) { port, engine, app in
            engine.onSpoolCreated = { url in created.value += [url] }
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            #expect(connected == 0)
            let head = Array("POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: application/octet-stream\r\nContent-Length: 20000000\r\n\r\n".utf8)
            let chunk = [UInt8](repeating: 7, count: 1_000_000)
            _ = head.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, head.count, 0) }
            _ = chunk.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, chunk.count, 0) }
            for _ in 0..<50 where created.value.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
            let url = try #require(created.value.first)
            #expect(FileManager.default.fileExists(atPath: url.path))

            try await app.stopAsync() // the client is still connected and mid-upload
            for _ in 0..<50 where FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(nanoseconds: 100_000_000) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func overTheLimitAnswers413AndDeletesThePartialFile() async throws {
        let created = Box<[URL]>([])
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("scw-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(count: 5_000_000).write(to: source)

        try await withServer({ app in
            app.mapPost("/up", maxRequestBodySize: 1_000_000, spoolBodyToDisk: true) { _ in "never" }
        }) { port, engine, _ in
            engine.onSpoolCreated = { url in created.value += [url] }
            for _ in 0..<5 {
                let status = try await send(port, "/up", file: source, contentType: "application/octet-stream").1.statusCode
                #expect(status == 413)
            }
            #expect(created.value.count == 5)
            #expect(created.value.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    @Test func clientDisconnectMidUploadDeletesTheTemporaryFile() async throws {
        let created = Box<[URL]>([])
        try await withServer({ app in
            app.mapPost("/up", maxRequestBodySize: 50_000_000, spoolBodyToDisk: true) { _ in "never" }
        }) { port, engine, _ in
            engine.onSpoolCreated = { url in created.value += [url] }

            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            #expect(connected == 0)
            let head = Array("POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: application/octet-stream\r\nContent-Length: 20000000\r\n\r\n".utf8)
            let chunk = [UInt8](repeating: 7, count: 1_000_000)
            _ = head.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, head.count, 0) }
            _ = chunk.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, chunk.count, 0) }

            for _ in 0..<50 where created.value.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
            let url = try #require(created.value.first)
            #expect(FileManager.default.fileExists(atPath: url.path), "the half-received body is on disk while the client is connected")

            close(descriptor) // gone with 19 MB still to come
            for _ in 0..<50 where FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(nanoseconds: 100_000_000) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
