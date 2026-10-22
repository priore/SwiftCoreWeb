// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A `multipart/form-data` parser (RFC 7578) over a fully buffered body.
enum MultipartParser {
    struct Part {
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data
    }

    /// The `boundary` parameter of a `Content-Type` header value, quotes removed.
    static func boundary(in contentType: String) throws -> String {
        for item in contentType.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "boundary" {
                let boundary = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !boundary.isEmpty { return boundary }
            }
        }
        throw HttpError(.badRequest, "Missing multipart boundary")
    }

    static func parse(_ body: Data, boundary: String) throws -> [Part] {
        // Prepending CRLF makes every delimiter, including the first, `CRLF--boundary`.
        let data = Data("\r\n".utf8) + body
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let truncated = HttpError(.badRequest, "Malformed multipart body")

        guard var cursor = data.range(of: delimiter)?.upperBound else { throw truncated }
        var parts: [Part] = []
        while !data[cursor...].starts(with: Data("--".utf8)) {
            guard data[cursor...].starts(with: Data("\r\n".utf8)),
                  let next = data.range(of: delimiter, in: (cursor + 2)..<data.endIndex) else { throw truncated }
            parts.append(try part(data[(cursor + 2)..<next.lowerBound]))
            cursor = next.upperBound
        }
        return parts
    }

    private static func part(_ chunk: Data) throws -> Part {
        guard let split = chunk.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: chunk[..<split.lowerBound], encoding: .utf8) else {
            throw HttpError(.badRequest, "Malformed multipart part")
        }
        let headers = head.components(separatedBy: "\r\n").compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let disposition = headers.first { $0.0 == "content-disposition" }?.1 ?? ""
        guard let name = parameter("name", in: disposition) else {
            throw HttpError(.badRequest, "Multipart part without a name")
        }
        return Part(
            name: name,
            filename: parameter("filename", in: disposition),
            contentType: headers.first { $0.0 == "content-type" }?.1,
            data: chunk[split.upperBound...]
        )
    }

    /// The quoted value of `key="..."` in a header value; the lookbehind keeps `name` from matching inside `filename`.
    private static func parameter(_ key: String, in header: String) -> String? {
        header.range(of: "(?<=[ ;]\(key)=\")[^\"]*(?=\")", options: .regularExpression).map { String(header[$0]) }
    }
}
