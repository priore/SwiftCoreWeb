// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a URL as a QR code via CoreImage's built-in generator — no
/// third-party dependency, per the plan's "Controlli" decision.
public struct QRCodeView: SwiftUI.View {
    private let url: URL
    private static let context = CIContext()

    public init(url: URL) {
        self.url = url
    }

    public var body: some SwiftUI.View {
        if let uiImage = Self.generate(for: url.absoluteString) {
            Image(uiImage: uiImage)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    private static func generate(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        // The raw CI output is a few pixels per module; scale up for a crisp,
        // non-blurry render instead of relying on the view's own resizing.
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
