// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// The big-endian integer at `offset` (relative to the start of this data, which must be zero-based).
    func bigEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        (0..<MemoryLayout<T>.size).reduce(T.zero) { ($0 << 8) | T(self[offset + $1]) }
    }
}
