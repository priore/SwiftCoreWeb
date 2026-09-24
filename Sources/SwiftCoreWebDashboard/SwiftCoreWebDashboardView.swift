// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftUI
import SwiftCoreWeb

/// Public entry point (the plan's step 2.9): drop-in replacement for a
/// showcase app's web view on the device's own screen.
///
/// ```swift
/// SwiftCoreWebDashboardView(app: app)
/// ```
///
/// Opens the on-disk metrics history itself (async — `MetricsHistory.init`
/// touches disk) and owns a `DashboardModel`; callers who need to inject a
/// test double or share a model across views should build `DashboardModel`
/// themselves and use `DashboardRootView`.
public struct SwiftCoreWebDashboardView: SwiftUI.View {
    private let app: WebApplication
    private let configuration: DashboardConfiguration
    @State private var model: DashboardModel?

    public init(app: WebApplication, configuration: DashboardConfiguration = .default) {
        self.app = app
        self.configuration = configuration
    }

    public var body: some SwiftUI.View {
        Group {
            if let model {
                DashboardRootView(model: model)
                    .onDisappear { model.stopSampling() }
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            let model = await DashboardModel.withDefaultHistory(app: app, configuration: configuration)
            model.startSampling()
            self.model = model
        }
    }
}
