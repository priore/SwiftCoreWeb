// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import NIOConcurrencyHelpers
import NIOCore

/// The open authenticated connections of each paired device, so revoking a device can close them.
final class ConnectionRegistry: Sendable {
    private let channels = NIOLockedValueBox<[String: [ObjectIdentifier: Channel]]>([:])

    func add(_ channel: Channel, deviceID: String) {
        let key = ObjectIdentifier(channel)
        channels.withLockedValue { $0[deviceID, default: [:]][key] = channel }
        channel.closeFuture.whenComplete { [channels] _ in
            channels.withLockedValue { $0[deviceID]?[key] = nil }
        }
    }

    func closeAll(deviceID: String) {
        let open = channels.withLockedValue { $0.removeValue(forKey: deviceID)?.values.map { $0 } ?? [] }
        for channel in open { channel.close(promise: nil) }
    }
}
