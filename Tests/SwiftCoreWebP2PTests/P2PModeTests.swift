// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWebP2P

final class P2PModeTests: XCTestCase {
    func testModesAreDistinct() {
        XCTAssertNotEqual(P2PMode.enable, P2PMode.disable)
    }
}
