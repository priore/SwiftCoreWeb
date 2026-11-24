// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// A "Copy" entry in the context menu; the Apple TV has no pasteboard, so there it adds nothing.
    @ViewBuilder
    func copyMenu(_ text: String) -> some View {
        #if os(tvOS)
        self
        #else
        contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        #endif
    }
}
