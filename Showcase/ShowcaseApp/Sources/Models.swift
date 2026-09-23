// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//
// Showcase sample. Not part of the SwiftCoreWeb library targets — see
// Showcase/README.md for how to wire these files into an Xcode app target.

import Foundation
import SwiftCoreWeb

/// A DTO used by both the macro-based controller and the closure routes.
/// `@ApiModel` gives it a compile-time-generated JSON schema for `/openapi.json`,
/// with zero reflection.
@ApiModel
struct Todo: Codable, Sendable {
    let id: Int
    let title: String
    let isDone: Bool
}

/// The shared in-memory store, registered with the DI container
/// (`builder.services.addSingleton`) and resolved in both controller and
/// closure handlers via `ctx.services.get(TodoStore.self)`.
final class TodoStore: @unchecked Sendable {
    private let lock = NSLock()
    private var todos: [Todo] = [
        Todo(id: 1, title: "Wire the WKWebView", isDone: true),
        Todo(id: 2, title: "Add JWT auth", isDone: false),
        Todo(id: 3, title: "Ship the showcase", isDone: false)
    ]

    func all() -> [Todo] {
        lock.lock(); defer { lock.unlock() }
        return todos
    }

    func find(_ id: Int) -> Todo? {
        lock.lock(); defer { lock.unlock() }
        return todos.first { $0.id == id }
    }

    func add(_ todo: Todo) {
        lock.lock(); defer { lock.unlock() }
        todos.append(todo)
    }
}
