// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation

/// One entry of the menu.
enum Demo: String, CaseIterable, Identifiable, Hashable {
    case hello, todos, livePages, realtime, dashboard, p2pHost, p2pClient, rendezvous, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hello: "Hello World"
        case .todos: "Todo API"
        case .livePages: "Live Pages"
        case .realtime: "Realtime"
        case .dashboard: "Device dashboard"
        case .p2pHost: "P2P host"
        case .p2pClient: "P2P client"
        case .rendezvous: "Rendezvous server"
        case .settings: "Remote access settings"
        }
    }

    var summary: String {
        switch self {
        case .hello: "Static Vue page and one JSON route."
        case .todos: "@Controller routes, JWT + API key, OpenAPI, security headers."
        case .livePages: "Server-driven page: Swift state, Vue template."
        case .realtime: "Server-Sent Events and a WebSocket echo."
        case .dashboard: "On-device metrics for a running server."
        case .p2pHost: "Pair devices and serve this app to them through a tunnel."
        case .p2pClient: "Pair with a host and call it through the tunnel."
        case .rendezvous: "The meeting point for devices on other networks."
        case .settings: "Rendezvous and TURN server used by the P2P host."
        }
    }

    var icon: String {
        switch self {
        case .hello: "hand.wave"
        case .todos: "checklist"
        case .livePages: "bolt.horizontal"
        case .realtime: "dot.radiowaves.left.and.right"
        case .dashboard: "gauge"
        case .p2pHost: "qrcode"
        case .p2pClient: "iphone.radiowaves.left.and.right"
        case .rendezvous: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape"
        }
    }
}
