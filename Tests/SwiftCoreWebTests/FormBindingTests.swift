// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWeb
import SwiftCoreWebTesting

final class FormBindingTests: XCTestCase {
    private let boundary = "XyZ"

    private func multipart(_ parts: [(header: String, body: Data)], closed: Bool = true) -> Data {
        var data = Data()
        for part in parts {
            data += Data("--\(boundary)\r\n\(part.header)\r\n\r\n".utf8) + part.body + Data("\r\n".utf8)
        }
        return closed ? data + Data("--\(boundary)--\r\n".utf8) : data
    }

    func testParserKeepsBinaryFileContainingCrlfAndBoundaryLookalike() throws {
        let binary = Data("a\r\n--Xy\r\nb".utf8) + Data([0, 255])
        let body = multipart([
            ("Content-Disposition: form-data; name=\"title\"", Data("hello".utf8)),
            ("Content-Disposition: form-data; name=\"f\"; filename=\"a;b.bin\"\r\nContent-Type: application/octet-stream", binary),
        ])
        let parts = try MultipartParser.parse(body, boundary: boundary)
        XCTAssertEqual(parts.map(\.name), ["title", "f"])
        XCTAssertEqual(parts[1].filename, "a;b.bin")
        XCTAssertEqual(parts[1].contentType, "application/octet-stream")
        XCTAssertEqual(parts[1].data, binary)
    }

    func testParserRejectsTruncatedBodyAndMissingBoundary() {
        let body = multipart([("Content-Disposition: form-data; name=\"a\"", Data("1".utf8))], closed: false)
        XCTAssertThrowsError(try MultipartParser.parse(body, boundary: boundary))
        XCTAssertThrowsError(try MultipartParser.boundary(in: "multipart/form-data"))
        XCTAssertEqual(try MultipartParser.boundary(in: "multipart/form-data; boundary=\"XyZ\"; charset=utf-8"), "XyZ")
    }

    func testFormHandlerReceivesFieldsAndFileThenTemporaryFileIsDeleted() async throws {
        let app = WebApplication.createBuilder().build()
        let path = PathBox()
        app.mapPost("/upload") { ctx in
            let form = try bindForm(ctx)
            path.value = form.files[0].temporaryPath
            let content = try String(contentsOfFile: form.files[0].temporaryPath, encoding: .utf8)
            return "\(form.fields["title"] ?? "")|\(form.files[0].fileName)|\(form.files[0].sizeInBytes)|\(content)"
        }
        let host = try await TestHost(app)
        let body = multipart([
            ("Content-Disposition: form-data; name=\"title\"", Data("hi".utf8)),
            ("Content-Disposition: form-data; name=\"f\"; filename=\"../x.txt\"", Data("data".utf8)),
        ])
        let response = try await host.post("/upload", body: body, headers: [("Content-Type", "multipart/form-data; boundary=\(boundary)")])
        XCTAssertEqual(response.bodyString, "hi|../x.txt|4|data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.value))
    }

    func testUrlEncodedFormAndUnsupportedContentType() async throws {
        let app = WebApplication.createBuilder().build()
        app.useExceptionHandler()
        app.mapPost("/form") { ctx in
            let form = try bindForm(ctx)
            return "\(form.fields["name"] ?? "")|\(form.fields["msg"] ?? "")"
        }
        let host = try await TestHost(app)
        let ok = try await host.post("/form", body: Data("name=Ada&msg=a+b%26c".utf8), headers: [("Content-Type", "application/x-www-form-urlencoded")])
        XCTAssertEqual(ok.bodyString, "Ada|a b&c")
        let bad = try await host.post("/form", body: Data("{}".utf8), headers: [("Content-Type", "application/json")])
        XCTAssertEqual(bad.status, 400)
    }

    #if DEBUG
    func testDevDeployRejectsTraversalFilename() {
        let body = multipart([("Content-Disposition: form-data; name=\"f\"; filename=\"../x\"", Data("x".utf8))])
        XCTAssertThrowsError(try MultipartFormData.writeFiles(from: body, contentType: "multipart/form-data; boundary=\(boundary)", into: FileManager.default.temporaryDirectory))
    }
    #endif
}

private final class PathBox: @unchecked Sendable { var value = "" }
