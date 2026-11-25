// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Network

/// What the device's network looks like right now, reduced to what the connection cares about.
struct NetworkPath: Equatable, Sendable {
    var isSatisfied: Bool
    /// The kinds of interface in use (`wifi`, `cellular`, `wired`, `other`): a change here means packets now leave another way.
    var interfaces: Set<String>
}

/// Where network changes come from: the system, or a test.
protocol NetworkPathSource: Sendable {
    func updates() -> AsyncStream<NetworkPath>
}

struct SystemPathSource: NetworkPathSource {
    func updates() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                var kinds: Set<String> = []
                if path.usesInterfaceType(.wifi) { kinds.insert("wifi") }
                if path.usesInterfaceType(.cellular) { kinds.insert("cellular") }
                if path.usesInterfaceType(.wiredEthernet) { kinds.insert("wired") }
                if kinds.isEmpty, path.status == .satisfied { kinds.insert("other") }
                continuation.yield(NetworkPath(isSatisfied: path.status == .satisfied, interfaces: kinds))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "SwiftCoreWebP2P.path", qos: .utility))
        }
    }
}

/// Turns a stream of paths into what to do about each.
struct NetworkPathTracker {
    enum Change: Equatable {
        /// Nothing worth acting on.
        case none
        /// No network: stop trying until it is back.
        case lost
        /// The network is back: try at once.
        case restored
        /// Still connected, but through another kind of interface: the connection in use leaves from an address that is gone.
        case rerouted
    }

    private var last: NetworkPath?

    mutating func observe(_ path: NetworkPath) -> Change {
        defer { last = path }
        guard let previous = last else { return path.isSatisfied ? .none : .lost }
        switch (previous.isSatisfied, path.isSatisfied) {
        case (true, false): return .lost
        case (false, true): return .restored
        case (true, true): return previous.interfaces != path.interfaces ? .rerouted : .none
        case (false, false): return .none
        }
    }
}
