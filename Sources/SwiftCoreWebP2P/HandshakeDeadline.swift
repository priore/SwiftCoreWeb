// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOConcurrencyHelpers
import NIOCore

/// Closes `channel` if it has not authenticated within `timeout`, so a socket that never speaks (or never proves a key)
/// cannot hold a slot forever. The server does not receive an authentication event in its pipeline, so the auth delegate
/// reports acceptance (`onAuthenticated`), which cancels the deadline.
final class HandshakeDeadline: Sendable {
    private let scheduled: NIOLockedValueBox<Scheduled<Void>?>

    init(channel: Channel, timeout: TimeAmount) {
        scheduled = NIOLockedValueBox(channel.eventLoop.scheduleTask(in: timeout) { channel.close(promise: nil) })
        channel.closeFuture.whenComplete { [scheduled] _ in scheduled.withLockedValue { $0?.cancel() } }
    }

    func cancel() {
        scheduled.withLockedValue { $0?.cancel() }
    }
}
