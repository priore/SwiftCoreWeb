// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// The hosting environment, mirroring .NET's `IHostEnvironment`.
///
/// Dev-only features (route list, OpenAPI UI, live reload, detailed errors)
/// only activate in `.development`. Defaults to `.development` when the
/// package is built with `DEBUG`, and `.production` otherwise.
public enum SwiftCoreWebEnvironment: String, Sendable, Codable {
    case development
    case production

    static var byDefault: SwiftCoreWebEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
}

/// Typed server options, optionally loaded from `appsettings.json` /
/// `appsettings.Development.json`. Secrets are never read from JSON; they
/// come from the Keychain (see `SecretStore`).
public struct ServerOptions: Codable, Sendable {
    public var host: String
    public var port: Int
    public var maxRequestBodySize: Int
    public var requestTimeoutSeconds: Double
    public var maxConcurrentConnections: Int
    public var maxHeaderSize: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        maxRequestBodySize: Int = 1_048_576,
        requestTimeoutSeconds: Double = 30,
        maxConcurrentConnections: Int = 64,
        maxHeaderSize: Int = 16_384
    ) {
        self.host = host
        self.port = port
        self.maxRequestBodySize = maxRequestBodySize
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxConcurrentConnections = maxConcurrentConnections
        self.maxHeaderSize = maxHeaderSize
    }
}

/// Typed CORS options consumed by `.useCors(_:)`.
public struct CorsOptions: Codable, Sendable {
    public var allowedOrigins: [String]
    public var allowedMethods: [String]
    public var allowedHeaders: [String]
    public var allowCredentials: Bool
    public var maxAgeSeconds: Int

    public init(
        allowedOrigins: [String] = [],
        allowedMethods: [String] = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allowedHeaders: [String] = ["Content-Type", "Authorization"],
        allowCredentials: Bool = false,
        maxAgeSeconds: Int = 600
    ) {
        self.allowedOrigins = allowedOrigins
        self.allowedMethods = allowedMethods
        self.allowedHeaders = allowedHeaders
        self.allowCredentials = allowCredentials
        self.maxAgeSeconds = maxAgeSeconds
    }

    /// A development preset that allows the Vite dev origin.
    public static var developmentPreset: CorsOptions {
        CorsOptions(allowedOrigins: ["http://localhost:5173", "http://*.local:5173"])
    }
}

/// Typed rate-limiting options consumed by `builder.rateLimit { ... }`.
public struct RateLimitOptions: Codable, Sendable {
    public var capacity: Int
    public var refillPerSecond: Double
    public var exemptLoopback: Bool
    public var maxTrackedClients: Int

    public init(
        capacity: Int = 60,
        refillPerSecond: Double = 10,
        exemptLoopback: Bool = true,
        maxTrackedClients: Int = 10_000
    ) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.exemptLoopback = exemptLoopback
        self.maxTrackedClients = maxTrackedClients
    }
}

/// Typed authentication options consumed by `.useAuthentication(_:)`.
public struct AuthOptions: Codable, Sendable {
    public var jwt: JwtOptionsCodable?

    public init(jwt: JwtOptionsCodable? = nil) {
        self.jwt = jwt
    }
}

/// A `Codable` mirror of `JwtOptions` for `appsettings.json` loading
/// (`JwtOptions` itself stays non-`Codable` since secrets belong in the
/// Keychain, not JSON — this type carries only the non-secret fields).
public struct JwtOptionsCodable: Codable, Sendable {
    public var issuer: String?
    public var audience: String?
    public var clockSkewSeconds: Double

    public init(issuer: String? = nil, audience: String? = nil, clockSkewSeconds: Double = 60) {
        self.issuer = issuer
        self.audience = audience
        self.clockSkewSeconds = clockSkewSeconds
    }
}
