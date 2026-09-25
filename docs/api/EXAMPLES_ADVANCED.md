# API track: advanced examples

[← docs index](../README.md)

You are here if: [Basic examples](EXAMPLES_BASIC.md) felt too small — this is a complete CRUD
API, end to end, the way you'd actually structure one.

This example is drawn directly from `Showcase/ShowcaseApp/` (a real, compilable app in this repo —
run it yourself via `Showcase/README.md`), trimmed to the CRUD-relevant parts.

## The model — `@ApiModel` for zero-reflection OpenAPI schemas

```swift
@ApiModel
struct Todo: Codable, Sendable {
    let id: Int
    let title: String
    let isDone: Bool
}
```

`@ApiModel` generates a compile-time JSON schema used by `/openapi.json` — no runtime reflection.

## A DI-registered store

```swift
final class TodoStore: @unchecked Sendable {
    private let lock = NSLock()
    private var todos: [Todo] = [
        Todo(id: 1, title: "Wire the WKWebView", isDone: true),
        Todo(id: 2, title: "Add JWT auth", isDone: false)
    ]

    func all() -> [Todo] { lock.lock(); defer { lock.unlock() }; return todos }
    func find(_ id: Int) -> Todo? { lock.lock(); defer { lock.unlock() }; return todos.first { $0.id == id } }
    func add(_ todo: Todo) { lock.lock(); defer { lock.unlock() }; todos.append(todo) }
}

builder.services.addSingleton { TodoStore() }
```

## The routes — `@Controller`, resolving the store via DI

```swift
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

    // Requires any authenticated identity — JWT or API-key, whichever scheme
    // is registered, both satisfy `.authenticated`. See AUTH_AND_SECURITY.md.
    @Post("/", auth: .authenticated, summary: "Creates a new todo item.")
    func create(_ todo: Todo, store: Service<TodoStore>) async throws -> Todo {
        store.wrappedValue.add(todo)
        return todo
    }

    // Restricted to the `admin` role, on top of requiring authentication.
    @Delete("/{id:int}", auth: .roles(["admin"]), summary: "Deletes a todo item (admin only).")
    func delete(id: Int) async throws {
        // ...
    }
}

app.mapControllers(TodoController.self)
```

`Service<T>` resolves from the DI container by declared type — note the explicit generic spelling;
the macro reads the parameter's type syntax, so it must appear as a type, not a property-wrapper
attribute.

## Wiring it together

```swift
let builder = WebApplication.createBuilder()
builder.services.addSingleton { TodoStore() }

let app = builder.build()
app.useExceptionHandler()
app.useAuthentication(.jwt(validate: JwtOptions(hmacSecret: SecretStore.read("jwtSigningSecret"))))
app.useAuthorization()
app.mapControllers(TodoController.self)
app.mapOpenApi(title: "My API", version: "1.0", models: [Todo.openApiSchema])
```

`GET /openapi.json` now serves a spec built from the compile-time route metadata and `@ApiModel`
schema — no separate annotation pass, no reflection.

## Rate limiting

```swift
builder.rateLimit { options in
    options.capacity = 60          // burst size
    options.refillPerSecond = 10   // steady-state rate
}
```

Token-bucket, applied before the request reaches your handlers — a client exceeding it gets a `429`
automatically, no code in your routes.

## Testing it

```swift
let host = try await TestHost(app)
let created = try await host.post("/api/todos", json: Todo(id: 4, title: "Ship it", isDone: false),
                                   headers: [("Authorization", "Bearer \(testToken)")])
#expect(created.status == 200)

let list = try await host.get("/api/todos")
let todos = try list.decode([Todo].self)
```

See [Testing guide](../TESTING_GUIDE.md) for the full `TestHost` walkthrough, including how
to generate `testToken`.

## Next

[Auth and security](AUTH_AND_SECURITY.md) covers the two-scheme (JWT + API key) setup this
example assumes, plus authorization policies.
