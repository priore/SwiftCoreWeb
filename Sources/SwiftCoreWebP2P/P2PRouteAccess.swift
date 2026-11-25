// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftCoreWeb

/// Which routes paired devices reach through the tunnel. Routes are reachable by default; the most specific rule wins.
/// A route a device may not reach answers `404`, as if it did not exist. The normal listeners are not affected.
///
/// ```swift
/// app.useP2P(.disable)                          // hide everything from paired devices by default...
/// app.mapGroup("/api").useP2P(.enable)          // ...except the API
/// app.useP2P("/api/admin", .disable)            // and except one part of it
/// ```
extension WebApplication {
    /// The default for every route no other rule names.
    @discardableResult
    public func useP2P(_ mode: P2PMode) -> Self {
        setPeerAccessDefault(allowed: mode == .enable)
    }

    /// The rule for `prefix` and everything below it (a `{placeholder}` segment matches any segment).
    @discardableResult
    public func useP2P(_ prefix: String, _ mode: P2PMode) -> Self {
        setPeerAccess(prefix, allowed: mode == .enable)
    }
}

extension RouteGroup {
    /// The rule for this group's prefix and everything below it, including nested groups.
    @discardableResult
    public func useP2P(_ mode: P2PMode = .enable) -> Self {
        setPeerAccess(allowed: mode == .enable)
    }
}
