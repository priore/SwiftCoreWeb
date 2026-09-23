// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// The lifetime of a registered service.
public enum ServiceLifetime: Sendable {
    /// One shared instance, created on first resolution.
    case singleton
    /// A new instance created on every resolution.
    case transient
}

/// A simple, reflection-free dependency injection container.
///
/// Services are keyed by `ObjectIdentifier` of their type, so registration
/// and resolution are both explicit — no type scanning, no `Mirror`.
public final class ServiceCollection: @unchecked Sendable {
    private struct Registration {
        let lifetime: ServiceLifetime
        let factory: @Sendable (ServiceProvider) -> any Sendable
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]

    public init() {}

    /// Registers a singleton service, built lazily on first resolution and
    /// shared for the lifetime of the application.
    public func addSingleton<T: Sendable>(_ factory: @escaping @Sendable (ServiceProvider) -> T) {
        registrations[ObjectIdentifier(T.self)] = Registration(lifetime: .singleton) { factory($0) }
    }

    /// Registers a singleton service built with no dependencies on the
    /// provider, for the common case (`builder.services.addSingleton { MyStore() }`).
    public func addSingleton<T: Sendable>(_ factory: @escaping @Sendable () -> T) {
        addSingleton { _ in factory() }
    }

    /// Registers a transient service, built fresh on every resolution.
    public func addTransient<T: Sendable>(_ factory: @escaping @Sendable (ServiceProvider) -> T) {
        registrations[ObjectIdentifier(T.self)] = Registration(lifetime: .transient) { factory($0) }
    }

    public func addTransient<T: Sendable>(_ factory: @escaping @Sendable () -> T) {
        addTransient { _ in factory() }
    }

    /// Builds the immutable, thread-safe `ServiceProvider` used at request time.
    func buildProvider() -> ServiceProvider {
        ServiceProvider(registrations: registrations.mapValues {
            ServiceProvider.Registration(lifetime: $0.lifetime, factory: $0.factory)
        })
    }
}

/// A read-only, thread-safe view over registered services, resolved by type.
///
/// Accessible from a request via `ctx.services.get(MyStore.self)`, and
/// bindable directly into a handler parameter with the `Service<T>` wrapper.
public final class ServiceProvider: @unchecked Sendable {
    struct Registration {
        let lifetime: ServiceLifetime
        let factory: @Sendable (ServiceProvider) -> any Sendable
    }

    private let registrations: [ObjectIdentifier: Registration]
    private let singletonLock = NSLock()
    private var singletonInstances: [ObjectIdentifier: any Sendable] = [:]

    init(registrations: [ObjectIdentifier: Registration]) {
        self.registrations = registrations
    }

    /// Resolves a registered service of type `T`.
    ///
    /// - Precondition: `T` must have been registered with `ServiceCollection`;
    ///   a missing registration is a programmer error and traps, mirroring
    ///   .NET's `GetRequiredService`.
    public func get<T: Sendable>(_ type: T.Type) -> T {
        guard let resolved = tryGet(type) else {
            preconditionFailure("SwiftCoreWeb: no service registered for \(T.self). Register it with builder.services.addSingleton or addTransient.")
        }
        return resolved
    }

    /// Resolves a registered service of type `T`, or `nil` if none was registered.
    public func tryGet<T: Sendable>(_ type: T.Type) -> T? {
        guard let registration = registrations[ObjectIdentifier(T.self)] else {
            return nil
        }
        switch registration.lifetime {
        case .transient:
            return registration.factory(self) as? T
        case .singleton:
            singletonLock.lock()
            defer { singletonLock.unlock() }
            if let existing = singletonInstances[ObjectIdentifier(T.self)] {
                return existing as? T
            }
            let instance = registration.factory(self)
            singletonInstances[ObjectIdentifier(T.self)] = instance
            return instance as? T
        }
    }
}

/// Explicit parameter-binding wrapper: resolves a service by type into a
/// handler parameter, per the parameter-binding rules.
@propertyWrapper
public struct Service<T: Sendable>: Sendable {
    public let wrappedValue: T

    public init(wrappedValue: T) {
        self.wrappedValue = wrappedValue
    }
}
