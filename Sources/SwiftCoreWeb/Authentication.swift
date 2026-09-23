// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// A single claim attached to an authenticated identity (e.g. `"sub"`, `"role"`).
public struct Claim: Sendable, Hashable {
    public let type: String
    public let value: String

    public init(type: String, value: String) {
        self.type = type
        self.value = value
    }
}

/// The authenticated identity for a request, populated by `.useAuthentication()`.
///
/// Exposed to handlers as `ctx.user`. `nil` means no scheme resolved a
/// principal for this request (anonymous).
public struct ClaimsPrincipal: Sendable {
    /// The claims presented by the credential (JWT payload entries, etc.).
    public let claims: [Claim]

    /// The roles extracted from the `"role"` claim(s), for `.roles([...])` checks.
    public let roles: [String]

    /// The name of the `AuthenticationScheme` that resolved this principal
    /// (e.g. `"jwt"`, `"basic"`, or a custom scheme name), so handlers and
    /// authorization checks can branch on which credential was presented.
    public let scheme: String

    public init(claims: [Claim], roles: [String] = [], scheme: String) {
        self.claims = claims
        self.roles = roles
        self.scheme = scheme
    }

    /// The first value for a claim type, if present.
    public func claim(_ type: String) -> String? {
        claims.first { $0.type == type }?.value
    }

    /// Whether this principal has the given role.
    public func isInRole(_ role: String) -> Bool {
        roles.contains(role)
    }
}

/// The authorization requirement attached to a route.
///
/// A route declared with no `auth:` argument defaults to `.none`: genuinely
/// public, with zero authentication middleware overhead for that path.
public enum AuthRequirement: Sendable {
    /// Public route; no authentication or authorization check runs.
    case none
    /// Any valid identity from any registered scheme is sufficient.
    case authenticated
    /// The resolved principal must have at least one of the given roles.
    case roles([String])
    /// The resolved principal must satisfy a named policy (registered via
    /// the authorization configuration).
    case policy(String)
    /// The resolved principal must have been authenticated by this specific
    /// named scheme (e.g. `.scheme("apiKey")`).
    case scheme(String)
}

/// A pluggable authentication scheme.
///
/// JWT and Basic auth are built-in implementations; conform your own type
/// for reuse across projects (e.g. an HMAC-signed header scheme), or use
/// `.custom(name:)` for a one-off closure-based scheme.
public protocol AuthenticationScheme: Sendable {
    /// A unique name for this scheme (e.g. `"jwt"`, `"apiKey"`), exposed on
    /// `ClaimsPrincipal.scheme` and matched by `AuthRequirement.scheme`.
    var name: String { get }

    /// Attempts to authenticate the request.
    ///
    /// - Returns: A resolved `ClaimsPrincipal`, or `nil` if this scheme
    ///   found no credential to evaluate (authentication continues with the
    ///   next registered scheme).
    /// - Throws: `HttpError(.unauthorized)` if a credential was presented
    ///   but is invalid (authentication stops; the request is rejected).
    func authenticate(_ request: HttpRequest) async throws -> ClaimsPrincipal?
}

/// Options for validating a JWT presented as a Bearer token.
public struct JwtOptions: Sendable {
    /// Shared secret for HS256 validation. Mutually exclusive with `publicKeyPEM`.
    public var hmacSecret: String?
    /// PEM-encoded public key for ES256/RS256 validation. Mutually exclusive with `hmacSecret`.
    public var publicKeyPEM: String?
    /// Expected `iss` (issuer) claim, if validation is required.
    public var issuer: String?
    /// Expected `aud` (audience) claim, if validation is required.
    public var audience: String?
    /// Allowed clock skew, in seconds, for `exp`/`nbf` validation.
    public var clockSkewSeconds: Double

    public init(
        hmacSecret: String? = nil,
        publicKeyPEM: String? = nil,
        issuer: String? = nil,
        audience: String? = nil,
        clockSkewSeconds: Double = 60
    ) {
        self.hmacSecret = hmacSecret
        self.publicKeyPEM = publicKeyPEM
        self.issuer = issuer
        self.audience = audience
        self.clockSkewSeconds = clockSkewSeconds
    }
}
