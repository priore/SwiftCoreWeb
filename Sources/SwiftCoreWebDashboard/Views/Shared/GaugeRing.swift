// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI

/// A circular progress ring for CPU/RAM/disk/battery, `Circle().trim`-based
/// since `Gauge` is iOS 16+ and the deployment target is iOS 15.
public struct GaugeRing: SwiftUI.View {
    private let progress: Double // 0...1
    private let ringColor: Color
    private let lineWidth: CGFloat

    public init(progress: Double, ringColor: Color = .accentColor, lineWidth: CGFloat = 6) {
        self.progress = min(max(progress, 0), 1)
        self.ringColor = ringColor
        self.lineWidth = lineWidth
    }

    public var body: some SwiftUI.View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
