// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftDiagnostics
import SwiftSyntax

/// The compile-time diagnostics emitted by `@Controller` and the method
/// marker macros, per the macro compile-time diagnostics design. Each case reads as a complete sentence so a
/// junior developer understands the fix without consulting docs.
enum RouteDiagnostic: String, DiagnosticMessage {
    case placeholderWithoutParameter
    case parameterWithoutPlaceholder
    case unsupportedParameterType
    case unsupportedReturnType
    case duplicateRoute
    case nonSendableController
    case invalidRouteTemplate
    case markerOnNonFunction

    var message: String {
        switch self {
        case .placeholderWithoutParameter:
            "Route template placeholder has no matching method parameter."
        case .parameterWithoutPlaceholder:
            "Method parameter does not match any route template placeholder, request body, or query binding."
        case .unsupportedParameterType:
            "Parameter type is not supported by SwiftCoreWeb's binding rules (HttpContext, LosslessStringConvertible, Decodable, Header<T>, Query<T>, Service<T>, or Form)."
        case .unsupportedReturnType:
            "Return type must be Void, String, an Encodable type, a View, or an HttpResult."
        case .duplicateRoute:
            "Duplicate route: this method and HTTP method combination is already registered on this controller."
        case .nonSendableController:
            "A @Controller type must be a final class, struct, or actor so its generated RouteProvider conformance is Sendable-safe."
        case .invalidRouteTemplate:
            "Invalid route template syntax."
        case .markerOnNonFunction:
            "Route marker macros can only be attached to a method."
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftCoreWeb", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }

    /// Builds a full diagnostic with a specific detail message and optional Fix-It.
    func at(_ node: some SyntaxProtocol, detail: String? = nil, fixIts: [FixIt] = []) -> Diagnostic {
        Diagnostic(
            node: Syntax(node),
            message: detail.map { DetailedMessage(base: self, detail: $0) } ?? self,
            fixIts: fixIts
        )
    }
}

/// Wraps a `RouteDiagnostic` with a call-site-specific detail suffix, so
/// e.g. "Route template placeholder has no matching method parameter: {id}"
/// names the exact offending placeholder.
private struct DetailedMessage: DiagnosticMessage {
    let base: RouteDiagnostic
    let detail: String

    var message: String { "\(base.message) \(detail)" }
    var diagnosticID: MessageID { base.diagnosticID }
    var severity: DiagnosticSeverity { base.severity }
}
