// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// `Range`/`If-Range` handling for any `.file` response (`Results.file`, static
/// files, downloads), applied once by the dispatcher after the pipeline so the
/// rule is the same for every handler: a satisfiable single range becomes
/// `206` + `Content-Range`, an unsatisfiable one `416` + `Content-Range: bytes */size`,
/// anything unparseable (or multi-range) is ignored and the full body is sent.
/// Only a `200` `.file` response that opted in via `acceptsRanges` is touched.
func applyByteRange(_ response: HttpResponse, for request: HttpRequest) -> HttpResponse {
    guard response.acceptsRanges, response.status == .ok,
          case .file(let path, nil) = response.body else { return response }
    var result = response
    result.headers["Accept-Ranges"] = "bytes"

    guard request.method == .get || request.method == .head,
          let header = request.headers["Range"],
          let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
          ifRangeAllows(request.headers["If-Range"], response: response) else { return result }

    if let range = parseByteRange(header, fileSize: size) {
        result.status = .partialContent
        result.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        result.body = .file(path: path, range: range)
    } else if isUnsatisfiableByteRange(header, fileSize: size) {
        result.status = HttpStatusCode(416)
        result.headers["Content-Range"] = "bytes */\(size)"
        result.body = .empty
    }
    return result
}

/// `If-Range` (RFC 9110 13.1.5): the range applies only if the validator still
/// matches. A weak `ETag` never matches (strong comparison), so such a client gets the full body.
/// ponytail: only a strong `ETag` or `Last-Modified` string match is honoured, no HTTP-date comparison.
private func ifRangeAllows(_ ifRange: String?, response: HttpResponse) -> Bool {
    guard let ifRange else { return true }
    if let etag = response.headers["ETag"], !etag.hasPrefix("W/"), etag == ifRange { return true }
    return response.headers["Last-Modified"] == ifRange
}

/// A well-formed single `bytes=` range that starts past the end of the file
/// (or is a zero-length suffix); malformed headers are not "unsatisfiable", they are ignored.
func isUnsatisfiableByteRange(_ header: String, fileSize: Int) -> Bool {
    guard header.hasPrefix("bytes="), !header.contains(",") else { return false }
    let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    if parts[0].isEmpty { return Int(parts[1]).map { $0 == 0 || fileSize == 0 } ?? false }
    guard let start = Int(parts[0]) else { return false }
    if let end = Int(parts[1]), end < start { return false }
    return start >= fileSize
}
