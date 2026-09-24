// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI

/// Switches between the two implemented looks (`DashboardStyle`) based on
/// `DashboardModel`'s persisted preference, with a picker to change it at
/// runtime — no relaunch needed (see the plan's step 2.7).
public struct DashboardRootView: SwiftUI.View {
    @ObservedObject private var model: DashboardModel

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some SwiftUI.View {
        Group {
            switch model.dashboardStyle {
            case .missionControl: MissionControlDashboardView(model: model)
            case .nativeCards: NativeCardsDashboardView(model: model)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Style", selection: $model.dashboardStyle) {
                Text("Mission Control").tag(DashboardStyle.missionControl)
                Text("Native Cards").tag(DashboardStyle.nativeCards)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}
