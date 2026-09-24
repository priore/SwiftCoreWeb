// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A location a `.p12` TLS identity is loaded from.
public enum P12Source: Sendable {
    case bundle(String)
    case documents(String)
    case path(String)
}

/// A location static/SPA content roots are resolved from.
public enum ContentRoot: Sendable {
    case bundle(String)
    case documents(String)
}

/// TLS configuration for a listener, built by `.useHttps(...)`.
public struct TlsOptions: Sendable {
    public let p12: P12Source
    public let passwordKeychainKey: String

    public init(p12: P12Source, passwordKeychainKey: String) {
        self.p12 = p12
        self.passwordKeychainKey = passwordKeychainKey
    }
}

/// The fluent builder for a `WebApplication`, in the style of .NET's
/// `WebApplicationBuilder`. Configures ports, binding, TLS, logging,
/// limits, services and environment, then `.build()` returns a `WebApplication`.
///
/// ```swift
/// let app = WebApplication.createBuilder().build()
/// app.mapGet("/hello") { "Hello, world!" }
/// try await app.runAsync()
/// ```
public final class WebApplicationBuilder: @unchecked Sendable {
    /// The hosting environment. Defaults to `.development` in `DEBUG` builds.
    public var environment: SwiftCoreWebEnvironment = .byDefault

    /// The dependency injection container. Register services before `.build()`.
    public let services = ServiceCollection()

    private(set) var serverOptions = ServerOptions()
    private(set) var corsOptions = CorsOptions()
    private(set) var rateLimitOptions: RateLimitOptions?
    private(set) var authOptions = AuthOptions()
    private(set) var tlsOptions: TlsOptions?
    private(set) var listenOnAllInterfacesFlag = false
    private(set) var bonjourName: String?
    private(set) var keepDeviceAwakeFlag = true

    init() {
        loadAppSettingsIfPresent()
    }

    // MARK: - Binding & TLS

    /// Enables HTTPS on this listener via TLS, with the identity loaded from
    /// a `.p12` file and its password read from the Keychain. HTTP and HTTPS
    /// may run side by side on different ports, sharing one router and pipeline.
    @discardableResult
    public func useHttps(p12: P12Source, passwordKeychainKey: String) -> Self {
        tlsOptions = TlsOptions(p12: p12, passwordKeychainKey: passwordKeychainKey)
        return self
    }

    /// Sets the port the server listens on. Defaults to `8080`.
    @discardableResult
    public func usePort(_ port: Int) -> Self {
        serverOptions.port = port
        return self
    }

    /// Binds to a specific host/interface address. Defaults to `127.0.0.1`
    /// (loopback only — secure by default).
    @discardableResult
    public func useHost(_ host: String) -> Self {
        serverOptions.host = host
        return self
    }

    /// Exposes the server on all network interfaces (LAN), instead of the
    /// secure-by-default loopback-only binding.
    @discardableResult
    public func listenOnAllInterfaces() -> Self {
        listenOnAllInterfacesFlag = true
        serverOptions.host = "0.0.0.0"
        return self
    }

    /// Advertises the server via Bonjour (`_http._tcp`) under `name`.
    @discardableResult
    public func advertise(name: String) -> Self {
        bonjourName = name
        return self
    }

    // MARK: - Limits

    /// Sets the maximum accepted request body size, in bytes. Over the limit
    /// returns `413 Payload Too Large`. Defaults to 1 MB.
    @discardableResult
    public func maxRequestBodySize(_ bytes: Int) -> Self {
        serverOptions.maxRequestBodySize = bytes
        return self
    }

    /// Sets the maximum time to wait for a request to complete before
    /// returning `408 Request Timeout`. Defaults to 30 seconds.
    @discardableResult
    public func requestTimeout(_ seconds: Double) -> Self {
        serverOptions.requestTimeoutSeconds = seconds
        return self
    }

    /// Sets the maximum number of concurrent connections; beyond this, new
    /// connections receive `503 Service Unavailable`. Defaults to 64.
    @discardableResult
    public func maxConcurrentConnections(_ count: Int) -> Self {
        serverOptions.maxConcurrentConnections = count
        return self
    }

    /// Sets the maximum accepted total header size, in bytes.
    @discardableResult
    public func maxHeaderSize(_ bytes: Int) -> Self {
        serverOptions.maxHeaderSize = bytes
        return self
    }

    // MARK: - Rate limiting

    /// Configures the early-gate token-bucket rate limiter (the early-gate rate limiting design). Runs before
    /// the middleware pipeline and before any body bytes are read.
    @discardableResult
    public func rateLimit(_ configure: (inout RateLimitOptions) -> Void) -> Self {
        var options = rateLimitOptions ?? RateLimitOptions()
        configure(&options)
        rateLimitOptions = options
        return self
    }

    // MARK: - Lifecycle

    /// Keeps the device awake (`isIdleTimerDisabled = true`) while the
    /// server runs and the app is foregrounded. Default `true`.
    @discardableResult
    public func keepDeviceAwake(_ enabled: Bool = true) -> Self {
        keepDeviceAwakeFlag = enabled
        return self
    }

    // MARK: - Configuration loading

    /// Loads `appsettings.json`, overlaid with `appsettings.Development.json`
    /// in `.development`, from the main bundle, into the typed options above.
    /// Silently does nothing if neither file is present — configuration
    /// files are optional.
    private func loadAppSettingsIfPresent() {
        struct AppSettings: Decodable {
            var server: ServerOptions?
            var cors: CorsOptions?
            var rateLimit: RateLimitOptions?
            var auth: AuthOptions?
        }

        func apply(_ url: URL) {
            guard let data = try? Data(contentsOf: url) else { return }
            guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return }
            if let server = decoded.server { serverOptions = server }
            if let cors = decoded.cors { corsOptions = cors }
            if let rateLimit = decoded.rateLimit { rateLimitOptions = rateLimit }
            if let auth = decoded.auth { authOptions = auth }
        }

        if let baseURL = Bundle.main.url(forResource: "appsettings", withExtension: "json") {
            apply(baseURL)
        }
        if environment == .development,
           let devURL = Bundle.main.url(forResource: "appsettings.Development", withExtension: "json") {
            apply(devURL)
        }
    }

    /// Builds and returns the `WebApplication`, freezing configuration.
    /// The returned application's router is immutable after this call
    /// returns from `mapGet`/`mapControllers`/etc. — routes may still be
    /// registered on the returned `WebApplication` before `runAsync()`.
    public func build() -> WebApplication {
        WebApplication(builder: self)
    }
}

/// The running (or not-yet-started) web application returned by
/// `WebApplicationBuilder.build()`. Routes are registered on it via the
/// Minimal API `map*` methods or `mapControllers(_:)`, middleware via
/// `.use(...)`, and the server is started with `runAsync()`.
public final class WebApplication: @unchecked Sendable {
    /// The configured environment, copied from the builder at `build()` time.
    public let environment: SwiftCoreWebEnvironment

    /// The resolved service provider, built from the builder's `ServiceCollection`.
    public let services: ServiceProvider

    let serverOptions: ServerOptions
    let corsOptions: CorsOptions
    let rateLimitOptions: RateLimitOptions?
    let authOptions: AuthOptions
    let tlsOptions: TlsOptions?
    let bonjourName: String?
    let keepDeviceAwakeFlag: Bool

    /// The reachable base URLs the server is listening on, populated once
    /// `runAsync()` has bound its listener(s).
    public var urls: [String] {
        get { urlsLock.lock(); defer { urlsLock.unlock() }; return urlsStorage }
        set { urlsLock.lock(); defer { urlsLock.unlock() }; urlsStorage = newValue }
    }
    private var urlsStorage: [String] = []
    private let urlsLock = NSLock()

    /// Whether the server engine is currently accepting connections.
    public var isRunning: Bool { engineBox.engine != nil }

    /// Backing store for the closure `map*` routing methods (see
    /// `MinimalApiRouting.swift`) and `mapControllers(_:)`.
    let routeRegistry = Router()

    /// Backing store for `mapWebSocket(_:_:)` (the realtime and OpenAPI contract design).
    let webSocketRegistry = WebSocketRegistry()

    /// The middleware pipeline (the middleware pipeline design), built by `.use(...)` and the
    /// `.use*()` extension methods below, in registration order.
    var middlewarePipeline = MiddlewarePipeline()

    /// The running server engine, set by `runAsync()` and torn down by
    /// `stopAsync()`.
    let engineBox = ServerEngineBox()

    /// Live server counters and recent-request ring (the on-device dashboard
    /// design). Always on — see `ServerMetrics` for why there is no toggle.
    public let metrics = ServerMetrics()

    init(builder: WebApplicationBuilder) {
        self.environment = builder.environment
        self.services = builder.services.buildProvider()
        self.serverOptions = builder.serverOptions
        self.corsOptions = builder.corsOptions
        self.rateLimitOptions = builder.rateLimitOptions
        self.authOptions = builder.authOptions
        self.tlsOptions = builder.tlsOptions
        self.bonjourName = builder.bonjourName
        self.keepDeviceAwakeFlag = builder.keepDeviceAwakeFlag
    }

    /// Creates a new `WebApplicationBuilder`.
    public static func createBuilder() -> WebApplicationBuilder {
        WebApplicationBuilder()
    }

    /// Starts the web server asynchronously and suspends while it runs.
    ///
    /// Binds the single NIOTS bootstrap (HTTP, and HTTPS if
    /// `.useHttps(...)` was configured), applies keep-awake, starts the
    /// network watchdog, rate limiter, and connection gate, and suspends
    /// until `stopAsync()` is called or the task is cancelled.
    public func runAsync() async throws {
        try await ServerEngine.start(for: self)
    }

    /// Stops the web server gracefully: stops accepting connections, drains
    /// in-flight requests up to `timeout` seconds, closes WebSocket clients,
    /// and closes sockets.
    public func stopAsync(timeout: Double = 10) async throws {
        try await engineBox.engine?.stop(timeout: timeout)
        engineBox.engine = nil
    }
}

/// Holds the running `ServerEngine` so it can be stopped from `stopAsync()`
/// and restarted from `LifecycleSupport`'s lifecycle binding. A separate box
/// (rather than a stored property on `WebApplication`) keeps `WebApplication`
/// itself free of engine/NIO types in its own file.
final class ServerEngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _engine: ServerEngine?

    var engine: ServerEngine? {
        get { lock.lock(); defer { lock.unlock() }; return _engine }
        set { lock.lock(); defer { lock.unlock() }; _engine = newValue }
    }
}
