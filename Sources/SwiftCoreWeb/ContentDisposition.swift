// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// How a client should treat a downloaded body (`Content-Disposition`, RFC 6266).
public enum ContentDisposition: String, Sendable {
    case attachment
    case inline
}

/// Strips everything from a client- or developer-supplied file name that could
/// escape the header or a directory: path components, control characters
/// (CR/LF included). Never returns an empty name.
func sanitizedFileName(_ name: String) -> String {
    let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let cleaned = String(String.UnicodeScalarView(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "download" : cleaned
}

/// RFC 5987 `attr-char`: what `filename*` may carry without percent-encoding.
private let attributeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)

/// `attachment; filename="<ascii fallback>"; filename*=UTF-8''<percent-encoded>`.
func contentDispositionHeader(fileName: String, disposition: ContentDisposition = .attachment) -> String {
    let name = sanitizedFileName(fileName)
    let fallback = String(String.UnicodeScalarView(name.unicodeScalars.map {
        (0x20...0x7E).contains($0.value) && !"\"\\%".unicodeScalars.contains($0) ? $0 : "_"
    }))
    let encoded = name.utf8.map { attributeCharacters.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    return "\(disposition.rawValue); filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
}
