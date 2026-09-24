// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftCoreWeb
import SwiftUI

/// Live tail of the most recent requests, newest first (mirrors
/// `ServerMetricsSnapshot.recentRequests`'s ring order).
public struct RequestLogView: SwiftUI.View {
    private let requests: [RecordedRequest]

    public init(requests: [RecordedRequest]) {
        self.requests = requests
    }

    public var body: some SwiftUI.View {
        List(requests.reversed(), id: \.timestamp) { request in
            HStack {
                Text(request.method)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(request.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text("\(request.statusCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(statusColor(request.statusCode))
                Text(String(format: "%.0f ms", request.durationMilliseconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private func statusColor(_ statusCode: Int) -> Color {
        switch statusCode / 100 {
        case 2: .green
        case 3: .blue
        case 4: .orange
        case 5: .red
        default: .secondary
        }
    }
}
