// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// How a single handler parameter is bound, per the convention-based rules
/// in the parameter-binding rules, decided entirely from the parameter's declared type and name —
/// no runtime type inspection.
enum ParameterBindingKind {
    case httpContext
    case routeValue(constraint: String?, isOptional: Bool, isCatchAll: Bool)
    case decodableBody
    case queryPrimitive(isOptional: Bool)
    case header(name: String, innerType: String)
    case query(name: String, innerType: String)
    case service(innerType: String)
    case form
}

/// A method parameter with the metadata needed to decide and emit its binding.
struct BindableParameter {
    let externalName: String
    let internalName: String
    let typeSyntax: TypeSyntax
    /// The type with a single leading `Header<...>`/`Query<...>`/`Service<...>`
    /// wrapper unwrapped, and whether that wrapper was present.
    let wrapperName: String?
    let innerTypeDescription: String?
    let isOptional: Bool
    let baseTypeDescription: String
}

/// The primitive scalar types bindable from a route placeholder or query
/// string via `LosslessStringConvertible`, per the parameter-binding rules.2/the parameter-binding rules.4. Kept as a
/// fixed list (rather than a protocol conformance check, unavailable at
/// macro-expansion time) so the diagnostic for an unsupported type is exact.
let primitiveTypeNames: Set<String> = ["Int", "String", "Bool", "Double", "UUID", "Float"]

/// Decides the binding for each parameter of a route handler method against
/// its route template placeholders, per the rule order in the parameter-binding rules, emitting a
/// diagnostic and returning `nil` for the whole signature on any failure.
func resolveParameterBindings(
    parameters: [BindableParameter],
    routeParameters: [RouteTemplateParameter],
    httpMethod: String,
    node: some SyntaxProtocol,
    context: some MacroExpansionContext
) -> [ParameterBindingKind]? {
    var bindings: [ParameterBindingKind] = []
    var matchedPlaceholders: Set<String> = []
    let routeParamsByName = Dictionary(uniqueKeysWithValues: routeParameters.map { ($0.name, $0) })
    let bodyEligibleMethods: Set<String> = ["POST", "PUT", "PATCH"]
    var sawBodyParameter = false

    for parameter in parameters {
        // Rule 1: HttpContext.
        if parameter.baseTypeDescription == "HttpContext" {
            bindings.append(.httpContext)
            continue
        }

        // Explicit wrappers (rule 5) take precedence once present.
        if let wrapperName = parameter.wrapperName, let inner = parameter.innerTypeDescription {
            switch wrapperName {
            case "Header":
                bindings.append(.header(name: parameter.externalName, innerType: inner))
                continue
            case "Query":
                bindings.append(.query(name: parameter.externalName, innerType: inner))
                continue
            case "Service":
                bindings.append(.service(innerType: inner))
                continue
            default:
                break
            }
        }
        if parameter.baseTypeDescription == "Form" {
            bindings.append(.form)
            continue
        }

        // Rule 2: matches a {placeholder}.
        if let routeParam = routeParamsByName[parameter.externalName] {
            matchedPlaceholders.insert(routeParam.name)
            if !primitiveTypeNames.contains(parameter.baseTypeDescription) {
                context.diagnose(RouteDiagnostic.unsupportedParameterType.at(
                    parameter.typeSyntax,
                    detail: "Parameter '\(parameter.externalName)' binds route placeholder '{\(routeParam.name)}' but its type '\(parameter.baseTypeDescription)' is not convertible from a path segment."
                ))
                return nil
            }
            bindings.append(.routeValue(constraint: routeParam.constraint, isOptional: routeParam.isOptional, isCatchAll: routeParam.isCatchAll))
            continue
        }

        // Rule 3: Decodable non-primitive body on POST/PUT/PATCH.
        if bodyEligibleMethods.contains(httpMethod), !primitiveTypeNames.contains(parameter.baseTypeDescription), parameter.wrapperName == nil {
            if sawBodyParameter {
                context.diagnose(RouteDiagnostic.unsupportedParameterType.at(
                    parameter.typeSyntax,
                    detail: "Only one Decodable request-body parameter is allowed per handler; '\(parameter.externalName)' is a second one."
                ))
                return nil
            }
            sawBodyParameter = true
            bindings.append(.decodableBody)
            continue
        }

        // Rule 4: primitive or optional primitive from the query string.
        if primitiveTypeNames.contains(parameter.baseTypeDescription) {
            bindings.append(.queryPrimitive(isOptional: parameter.isOptional))
            continue
        }

        context.diagnose(RouteDiagnostic.unsupportedParameterType.at(parameter.typeSyntax, detail: "Parameter '\(parameter.externalName)' has type '\(parameter.baseTypeDescription)'."))
        return nil
    }

    let unmatched = routeParameters.filter { !matchedPlaceholders.contains($0.name) }
    if let first = unmatched.first {
        context.diagnose(RouteDiagnostic.placeholderWithoutParameter.at(node, detail: "'{\(first.name)}' has no parameter named '\(first.name)'."))
        return nil
    }

    return bindings
}

/// Generates the expression that extracts and converts a bound parameter's
/// value inside the generated dispatch closure, throwing `HttpError(.badRequest)`
/// on conversion failure per the parameter-binding rules's "Conversion failure → 400" rule.
///
/// `parameterName` is the route/query/header key to read; `bodyTypeName` is
/// the concrete `Decodable` type name for `.decodableBody` (unused otherwise).
func bindingExpression(for binding: ParameterBindingKind, parameterName: String, bodyTypeName: String = "") -> String {
    switch binding {
    case .httpContext:
        return "ctx"
    case .routeValue(let constraint, let isOptional, let isCatchAll):
        if isCatchAll {
            return "ctx.request.routeValues[\"\(parameterName)\"] ?? \"\""
        }
        let converterType = constraint == "uuid" ? "UUID" : (constraint == "int" ? "Int" : "String")
        if isOptional {
            return "try SwiftCoreWeb.bindOptionalRouteValue(ctx.request.routeValues[\"\(parameterName)\"], as: \(converterType).self, parameterName: \"\(parameterName)\")"
        }
        return "try SwiftCoreWeb.bindRouteValue(ctx.request.routeValues[\"\(parameterName)\"], as: \(converterType).self, parameterName: \"\(parameterName)\")"
    case .decodableBody:
        return "try ctx.request.decode(\(bodyTypeName).self)"
    case .queryPrimitive(let isOptional):
        if isOptional {
            return "SwiftCoreWeb.bindOptionalQueryValue(ctx.request.query[\"\(parameterName)\"])"
        }
        return "try SwiftCoreWeb.bindQueryValue(ctx.request.query[\"\(parameterName)\"], parameterName: \"\(parameterName)\")"
    case .header(let name, _):
        return "SwiftCoreWeb.bindOptionalHeaderOrQueryValue(ctx.request.headers[\"\(name)\"])"
    case .query(let name, _):
        return "SwiftCoreWeb.bindOptionalHeaderOrQueryValue(ctx.request.query[\"\(name)\"])"
    case .service:
        return "ctx.services.get(\(bodyTypeName).self)"
    case .form:
        return "try SwiftCoreWeb.bindForm(ctx.request)"
    }
}

/// The explicit binding wrappers recognized by rule 5 (the parameter-binding rules.5).
private let bindingWrapperNames: Set<String> = ["Header", "Query", "Service"]

/// The `Encodable`-or-`Void`-or-`String`-or-`View`-or-`HttpResult` return
/// types recognized by the return-type conversion rules. A bare identifier is accepted here and trusted
/// to conform to `Encodable`/`HttpResultConvertible` at compile time by the
/// generated code itself — the macro cannot check protocol conformance, so
/// an actually-nonconforming type surfaces as a normal Swift compiler error
/// at the generated call site, not a macro diagnostic.
func describeType(_ type: TypeSyntax) -> (base: String, isOptional: Bool, wrapperName: String?, innerType: String?) {
    var syntax = type.trimmed
    var isOptional = false
    if let optional = syntax.as(OptionalTypeSyntax.self) {
        isOptional = true
        syntax = optional.wrappedType.trimmed
    }
    if let identified = syntax.as(IdentifierTypeSyntax.self) {
        let name = identified.name.text
        if bindingWrapperNames.contains(name),
           let generic = identified.genericArgumentClause?.arguments.first?.argument,
           let innerType = generic.as(TypeSyntax.self) {
            let inner = innerType.trimmedDescription
            return (name, isOptional, name, inner)
        }
        return (name, isOptional, nil, nil)
    }
    return (syntax.trimmedDescription, isOptional, nil, nil)
}

/// Extracts `BindableParameter`s from a handler's function signature.
func bindableParameters(from signature: FunctionSignatureSyntax) -> [BindableParameter] {
    signature.parameterClause.parameters.map { parameter in
        let externalName = (parameter.firstName.text == "_" ? parameter.secondName?.text : parameter.firstName.text) ?? parameter.firstName.text
        let internalName = (parameter.secondName ?? parameter.firstName).text
        let described = describeType(parameter.type)
        return BindableParameter(
            externalName: externalName,
            internalName: internalName,
            typeSyntax: parameter.type,
            wrapperName: described.wrapperName,
            innerTypeDescription: described.innerType,
            isOptional: described.isOptional,
            baseTypeDescription: described.base
        )
    }
}
