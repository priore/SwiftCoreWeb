// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

/// The compile-time-generated JSON Schema for an `@ApiModel`-annotated
/// `Codable` struct, consumed by `/openapi.json` generation (the realtime and OpenAPI contract design, Part 5).
///
/// `@ApiModel` generates `static var openApiSchema: OpenApiSchema` from the
/// struct's stored properties with no reflection; this type is only the
/// data shape that generated code populates.
public struct OpenApiSchema: Sendable {
    public struct Property: Sendable {
        /// A JSON Schema primitive type name: `"string"`, `"integer"`,
        /// `"number"`, `"boolean"`, or `"object"` for a nested type.
        public let type: String
        public let isOptional: Bool

        public init(type: String, isOptional: Bool) {
            self.type = type
            self.isOptional = isOptional
        }
    }

    public let typeName: String
    public let properties: [String: Property]

    public init(typeName: String, properties: [String: Property]) {
        self.typeName = typeName
        self.properties = properties
    }
}
