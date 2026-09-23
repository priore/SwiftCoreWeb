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

/// A macro-based controller (the pluggable authentication schemes design): `@Controller` generates
/// `registerRoutes(into:)` at compile time from the `@Get`/`@Post` markers
/// below — zero runtime reflection, zero type discovery beyond the explicit
/// `app.mapControllers(TodoController.self)` call in `ShowcaseServer`.
///
/// Every handler resolves `TodoStore` from the DI container with the
/// `Service<T>` parameter-binding wrapper (the parameter-binding rules.5) rather than a global, so
/// the same store instance is shared with the Minimal API closure routes in
/// `ShowcaseServer.registerMinimalApiRoutes`. Note the explicit generic
/// spelling `Service<TodoStore>` — the macro reads the parameter's declared
/// type syntax, so the wrapper must appear as a type, not as a
/// `@propertyWrapper` attribute on the parameter.
@Controller("/api/todos")
final class TodoController {
    @Get("/", summary: "Lists every todo item.")
    func list(store: Service<TodoStore>) async throws -> [Todo] {
        store.wrappedValue.all()
    }

    @Get("/{id:int}", summary: "Fetches a single todo item by id.")
    func get(id: Int, store: Service<TodoStore>) async throws -> Todo {
        guard let todo = store.wrappedValue.find(id) else {
            throw HttpError(.notFound, "No todo with id \(id)")
        }
        return todo
    }

    /// Requires any authenticated identity — either the JWT or the API-key
    /// scheme registered in `ShowcaseServer.makeApplication()` satisfies this.
    @Post("/", auth: .authenticated, summary: "Creates a new todo item.")
    func create(_ todo: Todo, store: Service<TodoStore>) async throws -> Todo {
        store.wrappedValue.add(todo)
        return todo
    }

    /// Restricted to the `admin` role, on top of requiring authentication.
    @Delete("/{id:int}", auth: .roles(["admin"]), summary: "Deletes a todo item (admin only).")
    func delete(id: Int) async throws {
        // ponytail: the in-memory demo store has no delete method yet;
        // add one if the showcase grows a real delete flow.
    }
}
