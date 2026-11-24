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
    private let owners = NIOLockedValueBox<[ObjectIdentifier: String]>([:])

    func add(_ channel: Channel, deviceID: String) {
        let key = ObjectIdentifier(channel)
        channels.withLockedValue { $0[deviceID, default: [:]][key] = channel }
        owners.withLockedValue { $0[key] = deviceID }
        channel.closeFuture.whenComplete { [channels, owners] _ in
            channels.withLockedValue { $0[deviceID]?[key] = nil }
            owners.withLockedValue { $0[key] = nil }
        }
    }

    /// The device that authenticated on `channel` (an SSH connection), if it is still open.
    func deviceID(for channel: Channel) -> String? {
        owners.withLockedValue { $0[ObjectIdentifier(channel)] }
    }

    func closeAll(deviceID: String) {
        let open = channels.withLockedValue { $0.removeValue(forKey: deviceID)?.values.map { $0 } ?? [] }
        for channel in open { channel.close(promise: nil) }
    }
}
