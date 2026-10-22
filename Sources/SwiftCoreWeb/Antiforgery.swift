// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import Security

/// The `__scw_af` antiforgery cookie shared by Live Pages and the one-time
/// download endpoints: a random value the browser sends back, which signed
/// snapshots and download tokens are bound to. No Vue/Pages/Session dependency.
enum Antiforgery {
    static let cookieName = "__scw_af"

    static func existing(_ request: HttpRequest) -> String? {
        request.cookies[cookieName]
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

extension WebApplication {
    /// The request's antiforgery value, or a freshly minted one together with
    /// the cookie to add to the response (`secure` under TLS).
    func antiforgery(for request: HttpRequest) -> (token: String, isNew: Bool) {
        if let existing = Antiforgery.existing(request) { return (existing, false) }
        return (Antiforgery.makeToken(), true)
    }

    func setAntiforgeryCookie(_ token: String, on response: inout HttpResponse) {
        response.setCookie(Antiforgery.cookieName, token, secure: tlsOptions != nil, sameSite: "Lax")
    }
}
