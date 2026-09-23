// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@ApiModel`: generates a `static var openApiSchema: OpenApiSchema`
/// computed entirely from the struct's stored properties at compile time —
/// no `Mirror`, no runtime type inspection — for `/openapi.json` (the realtime and OpenAPI contract design).
public struct ApiModelMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            context.diagnose(RouteDiagnostic.markerOnNonFunction.at(declaration, detail: "@ApiModel can only be attached to a struct."))
            return []
        }

        var propertyEntries: [String] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), variable.isStoredProperty else { continue }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let typeAnnotation = binding.typeAnnotation?.type else { continue }
                let described = describeType(typeAnnotation)
                let jsonType = Self.jsonSchemaType(for: described.base)
                propertyEntries.append(
                    "\"\(identifier)\": OpenApiSchema.Property(type: \"\(jsonType)\", isOptional: \(described.isOptional))"
                )
            }
        }

        let propertiesBlock = propertyEntries.map { "        \($0)" }.joined(separator: ",\n")
        let decl: DeclSyntax = """
        static var openApiSchema: OpenApiSchema {
            OpenApiSchema(typeName: "\(raw: typeName(of: declaration))", properties: [
        \(raw: propertiesBlock)
            ])
        }
        """
        return [decl]
    }

    private static func typeName(of declaration: some DeclGroupSyntax) -> String {
        declaration.as(StructDeclSyntax.self)?.name.text ?? "Unknown"
    }

    /// Maps a Swift stored-property type name to its JSON Schema primitive
    /// type name, for the `/openapi.json` document. Non-primitive (nested
    /// `Encodable`) types are reported as `"object"`; arrays are detected
    /// separately by `describeType`'s caller in a future iteration if needed.
    private static func jsonSchemaType(for swiftType: String) -> String {
        switch swiftType {
        case "Int", "Int32", "Int64": return "integer"
        case "Double", "Float": return "number"
        case "Bool": return "boolean"
        case "String", "UUID", "Date": return "string"
        default: return "object"
        }
    }
}

private extension VariableDeclSyntax {
    /// A stored property: `var`/`let` with no computed-property accessor
    /// block (a plain get/set-less binding, or one with only `willSet`/`didSet`).
    var isStoredProperty: Bool {
        bindings.allSatisfy { binding in
            guard let accessors = binding.accessorBlock else { return true }
            switch accessors.accessors {
            case .accessors(let list):
                return list.allSatisfy { $0.accessorSpecifier.tokenKind == .keyword(.willSet) || $0.accessorSpecifier.tokenKind == .keyword(.didSet) }
            case .getter:
                return false
            }
        }
    }
}
