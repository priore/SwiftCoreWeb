// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import XCTest
@testable import SwiftCoreWebP2P

final class P2PPairingViewTests: XCTestCase {
    @MainActor func testTheQRCodeIsRenderedForAPairingLink() throws {
        let payload = try XCTUnwrap(PairingPayload(host: "192.168.1.5", port: 49321, appPort: 8080, token: "abc", hostKeyFingerprint: "SHA256:AbCdEfGhIjKlMnOp"))
        let image = try XCTUnwrap(P2PPairingView.qrImage(for: payload.link))
        XCTAssertGreaterThan(image.width, 100)
        XCTAssertEqual(image.width, image.height)
    }

    @MainActor func testTheFingerprintIsShortenedWithoutItsPrefix() {
        XCTAssertEqual(P2PPairingView.shortFingerprint("SHA256:AbCdEfGhIjKlMnOp"), "AbCdEfGhIjKl")
    }

    @MainActor func testADeviceCaptionNamesItsKeyAndTheDateItPaired() throws {
        let device = try JSONDecoder().decode(PairedDevice.self, from: Data(#"{"id":"SHA256:AbCdEfGhIjKlMnOp","name":"iPhone 152D","publicKey":"ssh-ed25519 AAAA","pairedAt":0}"#.utf8))
        XCTAssertTrue(P2PPairingView.caption(for: device).hasSuffix("· key AbCdEfGhIjKl"))
        XCTAssertTrue(P2PPairingView.caption(for: device).hasPrefix("Paired "))
    }
}
