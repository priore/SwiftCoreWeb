// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWebP2P

final class P2PPairingViewTests: XCTestCase {
    func testTheQRCodeIsRenderedForAPairingLink() throws {
        let payload = try XCTUnwrap(PairingPayload(host: "192.168.1.5", port: 49321, appPort: 8080, token: "abc", hostKeyFingerprint: "SHA256:AbCdEfGhIjKlMnOp"))
        let image = try XCTUnwrap(P2PPairingView.qrImage(for: payload.link))
        XCTAssertGreaterThan(image.width, 100)
        XCTAssertEqual(image.width, image.height)
    }

    func testTheFingerprintIsShortenedWithoutItsPrefix() {
        XCTAssertEqual(P2PPairingView.shortFingerprint("SHA256:AbCdEfGhIjKlMnOp"), "AbCdEfGhIjKl")
    }
}
