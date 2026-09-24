// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI

/// A minimal line sparkline over a fixed set of values, normalized to its
/// own min/max. `Path`/`Shape` rather than Swift Charts: deployment target
/// is iOS 15 (see the plan's "Grafici" decision).
public struct Sparkline: SwiftUI.View {
    private let values: [Double]
    private let lineColor: Color

    public init(values: [Double], lineColor: Color = .accentColor) {
        self.values = values
        self.lineColor = lineColor
    }

    public var body: some SwiftUI.View {
        GeometryReader { geometry in
            path(in: geometry.size)
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func path(in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let range = max(maxValue - minValue, .leastNonzeroMagnitude)
        let stepX = size.width / CGFloat(values.count - 1)

        func point(_ index: Int) -> CGPoint {
            let normalized = (values[index] - minValue) / range
            let x = CGFloat(index) * stepX
            let y = size.height * (1 - CGFloat(normalized))
            return CGPoint(x: x, y: y)
        }

        path.move(to: point(0))
        for index in 1..<values.count {
            path.addLine(to: point(index))
        }
        return path
    }
}
