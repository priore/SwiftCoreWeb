// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//


import Foundation

/// `multipart/form-data` reader over a body already spooled to disk: same grammar as
/// `MultipartParser`, but the file is read in fixed-size blocks and every file part is
/// written straight to its own UUID-named file, so memory stays at about one block plus
/// the text fields. A delimiter that straddles two blocks is found because the last
/// `delimiter.count - 1` bytes of a block are carried over into the next window.
// ponytail: the spooled body and the parts cut out of it coexist on disk until the response ends
// (about 2x the upload, transient); parsing in place and handing out ranges needs a different `UploadedFile`.
enum MultipartFileParser {
    static let defaultBlockSize = 256 * 1024
    /// Text fields (all of them together) are kept in memory; over this the request is a `413`.
    static let maxFieldBytes = 1_048_576
    private static let maxHeaderBytes = 16 * 1024

    private enum State { case preamble, afterDelimiter, headers, content }

    /// One part being received: a text field in memory or a file part on disk.
    private final class Sink {
        let head: MultipartParser.PartHead
        var field = Data()
        var size = 0
        var url: URL?
        var handle: FileHandle?

        init(_ head: MultipartParser.PartHead, created: inout [URL]) throws {
            self.head = head
            guard head.filename != nil else { return }
            let url = try UploadStorage.newFileURL()
            created.append(url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            self.url = url
            handle = try FileHandle(forWritingTo: url)
        }
    }

    /// - Throws: `HttpError` `400` for a malformed body, `413` for text fields over `maxFieldBytes`.
    /// Files already written are deleted when it throws.
    static func parse(file: URL, boundary: String, blockSize: Int = defaultBlockSize, maxFieldBytes: Int = maxFieldBytes) throws -> Form {
        var created: [URL] = []
        do {
            return try read(file: file, boundary: boundary, blockSize: blockSize, maxFieldBytes: maxFieldBytes, created: &created)
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func read(file: URL, boundary: String, blockSize: Int, maxFieldBytes: Int, created: inout [URL]) throws -> Form {
        let malformed = HttpError(.badRequest, "Malformed multipart body")
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }

        // Prepending CRLF makes every delimiter, including the first, `CRLF--boundary`.
        var window = Data("\r\n".utf8)
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let overlap = delimiter.count - 1
        let blankLine = Data("\r\n\r\n".utf8)
        var state = State.preamble
        var sink: Sink?
        var fields: [String: String] = [:]
        var files: [UploadedFile] = []
        var fieldBytes = 0
        var finished = false

        func append(_ bytes: Data) throws {
            guard let sink, !bytes.isEmpty else { return }
            sink.size += bytes.count
            if let handle = sink.handle {
                try handle.write(contentsOf: bytes)
            } else {
                fieldBytes += bytes.count
                guard fieldBytes <= maxFieldBytes else { throw HttpError(.payloadTooLarge, "Form fields exceed \(maxFieldBytes) bytes") }
                sink.field.append(bytes)
            }
        }
        func complete() throws {
            guard let done = sink else { return }
            sink = nil
            if let handle = done.handle, let url = done.url {
                try handle.close()
                files.append(UploadedFile(fieldName: done.head.name, fileName: done.head.filename ?? "", contentType: done.head.contentType, temporaryPath: url.path, sizeInBytes: done.size))
            } else {
                guard let value = String(data: done.field, encoding: .utf8) else {
                    throw HttpError(.badRequest, "Form field '\(done.head.name)' is not valid UTF-8")
                }
                fields[done.head.name] = value
            }
        }

        while !finished {
            var progressed = true
            while progressed && !finished {
                progressed = false
                switch state {
                case .preamble:
                    if let found = window.range(of: delimiter) {
                        window = Data(window[found.upperBound...])
                        state = .afterDelimiter
                        progressed = true
                    } else if window.count > overlap {
                        window = Data(window.suffix(overlap))
                    }
                case .afterDelimiter:
                    guard window.count >= 2 else { break }
                    if window.starts(with: Data("--".utf8)) {
                        finished = true
                    } else if window.starts(with: Data("\r\n".utf8)) {
                        window = Data(window.dropFirst(2))
                        state = .headers
                        progressed = true
                    } else {
                        throw malformed
                    }
                case .headers:
                    if let found = window.range(of: blankLine) {
                        sink = try Sink(MultipartParser.partHead(Data(window[..<found.lowerBound])), created: &created)
                        window = Data(window[found.upperBound...])
                        state = .content
                        progressed = true
                    } else if window.count > maxHeaderBytes {
                        throw malformed
                    }
                case .content:
                    if let found = window.range(of: delimiter) {
                        try append(Data(window[..<found.lowerBound]))
                        try complete()
                        window = Data(window[found.upperBound...])
                        state = .afterDelimiter
                        progressed = true
                    } else if window.count > overlap {
                        try append(Data(window[..<(window.count - overlap)]))
                        window = Data(window.suffix(overlap))
                    }
                }
            }
            if finished { break }
            guard let block = try reader.read(upToCount: blockSize), !block.isEmpty else { throw malformed }
            window.append(block)
        }
        return Form(fields: fields, files: files)
    }
}
