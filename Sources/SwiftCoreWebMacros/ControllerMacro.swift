// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The HTTP-method marker macro names recognized on a `@Controller` method,
/// mapped to the `HttpMethod` case they imply. `@Route` is handled
/// separately since its method comes from its first argument.
private let markerMethodNames: [String: String] = [
    "Get": "GET", "Post": "POST", "Put": "PUT", "Patch": "PATCH",
    "Delete": "DELETE", "Head": "HEAD", "Options": "OPTIONS"
]

/// Expands `@Controller(prefix)`: generates `static func registerRoutes(into:)`
/// (member macro) and the `RouteProvider` conformance (extension macro) —
/// the only macro in SwiftCoreWeb that generates code, per the pluggable authentication schemes design. It re-walks
/// every `@Get`/`@Post`/etc. method exactly as `RouteMethodMacro` validated
/// it, and emits one `router.register(...)` call per route with a dispatch
/// closure that binds parameters and calls the method directly. No `Mirror`,
/// no string-based dispatch: every call site is written out at compile time.
public struct ControllerMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard isSendableEligible(declaration) else {
            context.diagnose(RouteDiagnostic.nonSendableController.at(declaration))
            return []
        }

        let prefix = controllerPrefix(from: node)

        var registrations: [String] = []
        var seenRouteKeys: Set<String> = []

        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard let marker = routeMarker(on: function) else { continue }
            guard let arguments = RouteMarkerArguments(node: marker, context: context) else { continue }

            guard let templateParameters = try? RouteTemplateParser.parse(arguments.path) else {
                continue // RouteMethodMacro already reported the syntax error
            }

            let normalizedRoutePath = RouteTemplateParser.normalizedPath(arguments.path, parameters: templateParameters)
            let fullPath = joinedPath(prefix: prefix, path: normalizedRoutePath)
            let routeKey = "\(arguments.method) \(fullPath)"
            if !seenRouteKeys.insert(routeKey).inserted {
                context.diagnose(RouteDiagnostic.duplicateRoute.at(function, detail: "'\(routeKey)'."))
                continue
            }

            let parameters = bindableParameters(from: function.signature)
            guard let bindings = resolveParameterBindings(
                parameters: parameters,
                routeParameters: templateParameters,
                httpMethod: arguments.method,
                node: function.signature,
                context: context
            ) else {
                continue // RouteMethodMacro already reported the binding error
            }

            let isVoidReturn = function.signature.returnClause == nil
                || describeType(function.signature.returnClause!.type).base == "Void"
            let isThrowing = function.signature.effectSpecifiers?.throwsSpecifier != nil
            let isAsync = function.signature.effectSpecifiers?.asyncSpecifier != nil

            registrations.append(generateRegistration(
                method: arguments.method,
                path: fullPath,
                authExpr: authExpression(from: marker),
                summaryExpr: summaryExpression(from: marker),
                functionName: function.name.text,
                parameters: parameters,
                bindings: bindings,
                isVoidReturn: isVoidReturn,
                isAsync: isAsync,
                isThrowing: isThrowing
            ))
        }

        let body = registrations.isEmpty ? "" : registrations.joined(separator: "\n")
        let decl: DeclSyntax = """
        static func registerRoutes(into router: RouteRegistry) {
        \(raw: body)
        }
        """
        return [decl]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Mirrors the member macro's own Sendable-eligibility gate: a
        // non-final class already failed there with `nonSendableController`,
        // so adding `RouteProvider` here too would just compound the error
        // with a conformance that has no `registerRoutes(into:)` to satisfy it.
        guard isSendableEligible(declaration) else { return [] }

        // `protocols` (the conformances the compiler still needs added) is
        // consulted, not required non-empty: a `@Controller` type can only
        // reach this macro because `@attached(extension, conformances:
        // RouteProvider)` names it, so the conformance always needs adding
        // unless the type already declared it by hand — and generating it
        // unconditionally is harmless there too (Swift merges the identical
        // conformance rather than erroring on it).
        let ext: DeclSyntax = "extension \(type.trimmed): RouteProvider {}"
        guard let extensionDecl = ext.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    // MARK: - Helpers

    private static func controllerPrefix(from node: AttributeSyntax) -> String {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let first = arguments.first,
              let stringLiteral = first.expression.as(StringLiteralExprSyntax.self) else {
            return ""
        }
        return stringLiteral.segments.compactMap { segment -> String? in
            if case .stringSegment(let literalSegment) = segment { return literalSegment.content.text }
            return nil
        }.joined()
    }

    private static func joinedPath(prefix: String, path: String) -> String {
        let trimmedPrefix = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        if path.isEmpty { return trimmedPrefix.isEmpty ? "/" : trimmedPrefix }
        let trimmedPath = path.hasPrefix("/") ? path : "/\(path)"
        return trimmedPrefix + trimmedPath
    }

    /// The `@Get`/`@Post`/.../`@Route` attribute on a method, if any.
    private static func routeMarker(on function: FunctionDeclSyntax) -> AttributeSyntax? {
        for element in function.attributes {
            guard case .attribute(let attribute) = element else { continue }
            let name = attribute.attributeName.trimmedDescription
            if markerMethodNames[name] != nil || name == "Route" {
                return attribute
            }
        }
        return nil
    }

    private static func authExpression(from marker: AttributeSyntax) -> String {
        namedArgumentExpression(marker, label: "auth") ?? "AuthRequirement.none"
    }

    private static func summaryExpression(from marker: AttributeSyntax) -> String {
        namedArgumentExpression(marker, label: "summary") ?? "nil"
    }

    private static func namedArgumentExpression(_ marker: AttributeSyntax, label: String) -> String? {
        guard let arguments = marker.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        return arguments.first { $0.label?.text == label }?.expression.trimmedDescription
    }

    /// `@Controller` requires a `final class`, `struct`, or `actor` so the
    /// generated `RouteProvider` conformance and its captured handlers stay
    /// `Sendable`-safe under strict Swift 6 concurrency checking.
    private static func isSendableEligible(_ declaration: some DeclGroupSyntax) -> Bool {
        if declaration.is(StructDeclSyntax.self) || declaration.is(ActorDeclSyntax.self) {
            return true
        }
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            return classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
        }
        return false
    }

    /// Emits one `router.register(...)` call for a single route, with a
    /// dispatch closure that binds each parameter and invokes the method
    /// directly — the generated call site `@Controller` promises in the pluggable authentication schemes design.
    private static func generateRegistration(
        method: String,
        path: String,
        authExpr: String,
        summaryExpr: String,
        functionName: String,
        parameters: [BindableParameter],
        bindings: [ParameterBindingKind],
        isVoidReturn: Bool,
        isAsync: Bool,
        isThrowing: Bool
    ) -> String {
        var argumentLines: [String] = []
        var callArguments: [String] = []
        for (parameter, binding) in zip(parameters, bindings) {
            let bodyTypeName = describeType(parameter.typeSyntax).base
            let expr = bindingExpression(for: binding, parameterName: parameter.externalName, bodyTypeName: bodyTypeName)
            let localName = "arg_\(parameter.internalName)"
            argumentLines.append("let \(localName) = \(expr)")
            callArguments.append("\(parameter.internalName): \(localName)")
        }

        // Mirrors .NET's per-request controller instantiation: a fresh
        // instance is created for each dispatch (cheap — controllers hold
        // no per-request state of their own; request-scoped state lives on
        // HttpContext), so instance methods need no reflection and no
        // shared mutable controller state to reason about under Swift 6
        // concurrency. Requires a no-argument initializer, same as ASP.NET
        // controllers require a constructor DI can satisfy with no arguments
        // beyond what's registered.
        let awaitTry = "\(isThrowing ? "try " : "")\(isAsync ? "await " : "")"
        // `Self.init()` rather than `Self()`: the swift-syntax 509.x
        // formatter (`.formatted()`, used by macro expansion) misformats a
        // bare `Self()` call as `Self ()`; the explicit `.init()` spelling
        // is unaffected and expands identically at compile time.
        let call = "\(awaitTry)Self.init().\(functionName)(\(callArguments.joined(separator: ", ")))"
        let resultLine = isVoidReturn
            ? "\(call)\n    return SwiftCoreWeb.voidHttpResult()"
            : "return try \(call.hasPrefix("try ") ? String(call.dropFirst(4)) : call).toHttpResult()"

        let argumentsBlock = argumentLines.map { "    \($0)" }.joined(separator: "\n")
        return """
        router.register(method: .\(method.lowercased()), path: "\(path)", auth: \(authExpr), summary: \(summaryExpr)) { ctx in
        \(argumentsBlock.isEmpty ? "" : argumentsBlock + "\n")    \(resultLine)
        }
        """
    }
}
