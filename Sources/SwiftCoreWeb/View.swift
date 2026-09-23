// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// A server-rendered HTML view, produced by the template engine (the server-side template engine design).
///
/// Returned directly from a handler like any other `HttpResultConvertible`
/// return type. Rendering (token replacement, model flattening) is
/// implemented by the template engine delivered with Web Hosting & Vue.
public struct View: Sendable, HttpResultConvertible {
    /// The template's resource name (e.g. `"index.html"`).
    public let templateName: String

    /// The model's fields, flattened to a JSON-compatible dictionary via
    /// `JSONEncoder` — no reflection.
    public let modelData: Data?

    public init<T: Encodable>(_ templateName: String, model: T) {
        self.templateName = templateName
        self.modelData = try? JSONEncoder().encode(model)
    }

    public init(_ templateName: String) {
        self.templateName = templateName
        self.modelData = nil
    }

    // `toHttpResult()` is implemented in TemplateEngine.swift (Part 5),
    // where the rendering engine itself lives.
}
