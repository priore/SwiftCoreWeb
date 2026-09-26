// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

extension HttpRequest {
    /// Cookies sent by the client, parsed from the `Cookie` header
    /// (`name=value; name2=value2`). Malformed pairs (no `=`) are skipped.
    public var cookies: [String: String] {
        guard let header = headers["Cookie"] else { return [:] }
        var result: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separatorIndex])
            let value = String(trimmed[trimmed.index(after: separatorIndex)...])
            result[name] = value
        }
        return result
    }
}

extension HttpResponse {
    /// Appends a `Set-Cookie` header. `maxAge` in seconds omits `Max-Age`
    /// (session cookie) when `nil`; pass `0` to delete a cookie.
    public mutating func setCookie(
        _ name: String,
        _ value: String,
        path: String = "/",
        httpOnly: Bool = true,
        secure: Bool = false,
        sameSite: String = "Lax",
        maxAge: Int? = nil
    ) {
        var attributes = "\(name)=\(value); Path=\(path); SameSite=\(sameSite)"
        if httpOnly { attributes += "; HttpOnly" }
        if secure { attributes += "; Secure" }
        if let maxAge { attributes += "; Max-Age=\(maxAge)" }
        headers.add("Set-Cookie", attributes)
    }
}
