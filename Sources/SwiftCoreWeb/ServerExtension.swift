// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A transport that runs next to the HTTP listener for as long as the server does (registered with
/// `WebApplicationBuilder.addExtension(_:)`). `start` runs once the listeners are bound and must return when
/// the setup is done, quickly (a `stopAsync()` arriving meanwhile is ignored, as during the bind; do not run the transport's loop inside it); `stop` runs when the server stops.
/// Each (re)start of the server calls `start` again with a fresh `RequestIngress`, so a stopped extension
/// must be startable again.
public protocol ServerExtension: Sendable {
    func start(ingress: RequestIngress) async throws
    /// May run without a prior `start` (a failed bind) or more than once: keep it idempotent.
    func stop() async
}

extension WebApplicationBuilder {
    /// Runs `serverExtension` alongside the server. Not registered, not running: modules stay opt-in.
    @discardableResult
    public func addExtension(_ serverExtension: some ServerExtension) -> Self {
        extensions.append(serverExtension)
        return self
    }
}
