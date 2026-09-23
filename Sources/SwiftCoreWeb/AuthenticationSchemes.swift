// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import CryptoKit
import Security

/// A type-erased `AuthenticationScheme`, so `.jwt`/`.basic`/`.custom` factory
/// methods and arbitrary user `AuthenticationScheme` conformances can be
/// stored together in `.useAuthentication(_:)`'s variadic list.
public struct AnyAuthenticationScheme: AuthenticationScheme, Sendable {
    public let name: String
    private let authenticateImpl: @Sendable (HttpRequest) async throws -> ClaimsPrincipal?

    public init(_ scheme: some AuthenticationScheme) {
        self.name = scheme.name
        self.authenticateImpl = { try await scheme.authenticate($0) }
    }

    public init(name: String, authenticate: @escaping @Sendable (HttpRequest) async throws -> ClaimsPrincipal?) {
        self.name = name
        self.authenticateImpl = authenticate
    }

    public func authenticate(_ request: HttpRequest) async throws -> ClaimsPrincipal? {
        try await authenticateImpl(request)
    }
}

/// Factory methods for the built-in authentication schemes (the pluggable authentication schemes design).
extension AnyAuthenticationScheme {
    /// Bearer JWT authentication: HS256 via CryptoKit HMAC, ES256/RS256 via
    /// the Security framework. Validates `exp`, `nbf`, `iss`, `aud` with
    /// configurable clock skew.
    public static func jwt(validate options: JwtOptions) -> AnyAuthenticationScheme {
        AnyAuthenticationScheme(name: "jwt") { request in
            guard let authorization = request.headers["Authorization"],
                  authorization.lowercased().hasPrefix("bearer ") else {
                return nil
            }
            let token = String(authorization.dropFirst("bearer ".count))
            do {
                let claims = try JwtValidator.validate(token, options: options)
                let roles = claims.filter { $0.type == "role" }.map(\.value)
                return ClaimsPrincipal(claims: claims, roles: roles, scheme: "jwt")
            } catch {
                throw HttpError(.unauthorized, "Invalid bearer token: \(error)")
            }
        }
    }

    /// HTTP Basic authentication with a constant-time credential comparison
    /// left to the caller's validator closure.
    public static func basic(validate: @escaping @Sendable (String, String) async -> Bool) -> AnyAuthenticationScheme {
        AnyAuthenticationScheme(name: "basic") { request in
            guard let authorization = request.headers["Authorization"],
                  authorization.lowercased().hasPrefix("basic ") else {
                return nil
            }
            let encoded = String(authorization.dropFirst("basic ".count))
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8),
                  let separatorIndex = decoded.firstIndex(of: ":") else {
                throw HttpError(.unauthorized, "Malformed Basic credentials")
            }
            let username = String(decoded[decoded.startIndex..<separatorIndex])
            let password = String(decoded[decoded.index(after: separatorIndex)...])
            guard await validate(username, password) else {
                throw HttpError(.unauthorized, "Invalid Basic credentials")
            }
            return ClaimsPrincipal(claims: [Claim(type: "sub", value: username)], scheme: "basic")
        }
    }

    /// A custom, one-off closure-based scheme registered under `name`
    /// (e.g. an API key header). For a scheme reused across projects,
    /// conform a type to `AuthenticationScheme` instead.
    public static func custom(_ name: String, _ authenticate: @escaping @Sendable (HttpRequest) async throws -> ClaimsPrincipal?) -> AnyAuthenticationScheme {
        AnyAuthenticationScheme(name: name, authenticate: authenticate)
    }
}

/// JWT (RFC 7519) validation: HS256 via CryptoKit HMAC, ES256/RS256 via the
/// Security framework. No third-party JWT library, per the dependency policy.
enum JwtValidator {
    enum ValidationError: Error, CustomStringConvertible {
        case malformed
        case unsupportedAlgorithm(String)
        case badSignature
        case expired
        case notYetValid
        case issuerMismatch
        case audienceMismatch
        case missingKey

        var description: String {
            switch self {
            case .malformed: return "malformed token"
            case .unsupportedAlgorithm(let alg): return "unsupported algorithm '\(alg)'"
            case .badSignature: return "signature verification failed"
            case .expired: return "token expired"
            case .notYetValid: return "token not yet valid"
            case .issuerMismatch: return "issuer mismatch"
            case .audienceMismatch: return "audience mismatch"
            case .missingKey: return "no signing key configured"
            }
        }
    }

    static func validate(_ token: String, options: JwtOptions) throws -> [Claim] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ValidationError.malformed }
        let headerPart = parts[0], payloadPart = parts[1], signaturePart = parts[2]

        guard let headerData = base64URLDecode(headerPart),
              let payloadData = base64URLDecode(payloadPart),
              let signature = base64URLDecode(signaturePart),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let algorithm = header["alg"] as? String else {
            throw ValidationError.malformed
        }

        let signedInput = Data("\(headerPart).\(payloadPart)".utf8)
        try verifySignature(algorithm: algorithm, signedInput: signedInput, signature: signature, options: options)

        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ValidationError.malformed
        }

        let now = Date().timeIntervalSince1970
        if let exp = payload["exp"] as? Double, now > exp + options.clockSkewSeconds {
            throw ValidationError.expired
        }
        if let nbf = payload["nbf"] as? Double, now < nbf - options.clockSkewSeconds {
            throw ValidationError.notYetValid
        }
        if let expectedIssuer = options.issuer {
            guard let issuer = payload["iss"] as? String, issuer == expectedIssuer else {
                throw ValidationError.issuerMismatch
            }
        }
        if let expectedAudience = options.audience {
            let audiences: [String]
            if let single = payload["aud"] as? String { audiences = [single] }
            else if let many = payload["aud"] as? [String] { audiences = many }
            else { audiences = [] }
            guard audiences.contains(expectedAudience) else { throw ValidationError.audienceMismatch }
        }

        return payload.map { key, value in
            Claim(type: key, value: jsonClaimValueString(value))
        }
    }

    private static func verifySignature(algorithm: String, signedInput: Data, signature: Data, options: JwtOptions) throws {
        switch algorithm {
        case "HS256":
            guard let secret = options.hmacSecret, let keyData = secret.data(using: .utf8) else {
                throw ValidationError.missingKey
            }
            let key = SymmetricKey(data: keyData)
            let expected = HMAC<SHA256>.authenticationCode(for: signedInput, using: key)
            guard Data(expected) == signature else { throw ValidationError.badSignature }

        case "ES256":
            guard let pem = options.publicKeyPEM else { throw ValidationError.missingKey }
            let key = try P256.Signing.PublicKey(pemRepresentation: pem)
            guard let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
                  key.isValidSignature(ecdsaSignature, for: signedInput) else {
                throw ValidationError.badSignature
            }

        case "RS256":
            guard let pem = options.publicKeyPEM else { throw ValidationError.missingKey }
            try verifyRS256(pem: pem, signedInput: signedInput, signature: signature)

        default:
            throw ValidationError.unsupportedAlgorithm(algorithm)
        }
    }

    /// RS256 verification via the Security framework (no OpenSSL, per the
    /// dependency policy): imports the PEM public key and runs
    /// `SecKeyVerifySignature` with PKCS#1v1.5/SHA-256.
    private static func verifyRS256(pem: String, signedInput: Data, signature: Data) throws {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard let keyData = Data(base64Encoded: stripped) else { throw ValidationError.badSignature }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw ValidationError.badSignature
        }
        guard SecKeyVerifySignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedInput as CFData,
            signature as CFData,
            &error
        ) else {
            throw ValidationError.badSignature
        }
    }

    private static func base64URLDecode(_ input: Substring) -> Data? {
        var base64 = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    private static func jsonClaimValueString(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
}
