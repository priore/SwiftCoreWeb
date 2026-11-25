// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.

import Foundation
import SwiftCoreWeb

/// A DTO shared by the controller and the closure routes. `@ApiModel` generates its OpenAPI schema at compile time.
@ApiModel
struct Todo: Codable, Sendable {
    let id: Int
    let title: String
    let isDone: Bool
}

/// The in-memory store, registered with the DI container and resolved in controller and closure handlers alike.
final class TodoStore: @unchecked Sendable {
    private let lock = NSLock()
    private var todos: [Todo] = [
        Todo(id: 1, title: "Wire the WKWebView", isDone: true),
        Todo(id: 2, title: "Add JWT auth", isDone: false),
        Todo(id: 3, title: "Ship the showcase", isDone: false)
    ]

    func all() -> [Todo] { lock.lock(); defer { lock.unlock() }; return todos }
    func find(_ id: Int) -> Todo? { lock.lock(); defer { lock.unlock() }; return todos.first { $0.id == id } }
    func add(_ todo: Todo) { lock.lock(); defer { lock.unlock() }; todos.append(todo) }

    @discardableResult
    func remove(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return false }
        todos.remove(at: index)
        return true
    }
}
