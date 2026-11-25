// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation
import SwiftCoreWeb

/// Shared state of the menu app: the server runner, the remote-access settings and the pairing link handed over by the
/// system when a `scw-p2p://` QR code is opened.
@MainActor
final class AppModel: ObservableObject {
    let runner = ServerRunner()
    let settings = RemoteSettings()
    @Published var path: [Demo] = []
    @Published var pairingLink: String?

    /// `-demo todos` as a launch argument opens that screen directly (handy for UI tests and screenshots).
    init() {
        if let raw = UserDefaults.standard.string(forKey: "demo"), let demo = Demo(rawValue: raw) { path = [demo] }
    }

    func openPairingLink(_ url: URL) {
        pairingLink = url.absoluteString
        path = [.p2pClient]
    }
}

/// Starts and stops `WebApplication`s by name, so a demo screen can bind port 8080 only after the previous server is gone.
@MainActor
final class ServerRunner {
    private final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Error?
        func set(_ error: Error) { lock.lock(); value = error; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private var running: [String: (app: WebApplication, task: Task<Void, Never>)] = [:]

    func start(_ key: String, _ app: WebApplication) async throws {
        await stop(key)
        let failure = Failure()
        let task = Task.detached {
            do { try await app.runAsync() } catch { failure.set(error) }
        }
        running[key] = (app, task)
        let deadline = Date().addingTimeInterval(5)
        // Any way out without a running server (failure, timeout, the screen leaving) releases the port again.
        do {
            while !app.isRunning {
                if let error = failure.get() { running[key] = nil; throw error }
                if Date() > deadline { throw ShowcaseError.startTimeout }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            await stop(key, ifApp: app)
            throw error
        }
    }

    /// With `app`, stops only that instance: a screen leaving must not stop the server its successor has just started.
    func stop(_ key: String, ifApp app: WebApplication? = nil) async {
        if let app, running[key]?.app !== app { return }
        guard let entry = running.removeValue(forKey: key) else { return }
        if entry.app.isRunning { try? await entry.app.stopAsync(timeout: 5) }
        await entry.task.value
    }

    func isRunning(_ key: String) -> Bool { running[key]?.app.isRunning ?? false }
}

enum ShowcaseError: Error, LocalizedError {
    case startTimeout
    var errorDescription: String? { "The server did not start in time." }
}
