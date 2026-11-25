// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel

    private let groups: [(String, [Demo])] = [
        ("Web & API", [.hello, .todos, .livePages, .realtime]),
        ("Device", [.dashboard]),
        ("Peer-to-peer", [.p2pHost, .p2pClient, .rendezvous, .settings])
    ]

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { demo in
                            NavigationLink(value: demo) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(demo.title)
                                        Text(demo.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: demo.icon) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("SwiftCoreWeb")
            .navigationDestination(for: Demo.self) { demo in
                DemoScreen(demo: demo).navigationTitle(demo.title).navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct DemoScreen: View {
    let demo: Demo

    var body: some View {
        switch demo {
        case .hello: WebDemoView(key: "web", path: "/", make: HelloServer.make)
        case .todos: WebDemoView(key: "web", path: "/", make: TodoServer.make)
        case .livePages: WebDemoView(key: "web", path: "/counter", make: LivePagesServer.make)
        case .realtime: WebDemoView(key: "web", path: "/", make: RealtimeServer.make)
        case .dashboard: DashboardDemoView()
        case .p2pHost: P2PHostView()
        case .p2pClient: P2PClientView()
        case .rendezvous: RendezvousView()
        case .settings: SettingsView()
        }
    }
}
