// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Explicit parameter-binding wrapper: reads a header value into a handler
/// parameter, per the binding rules in the parameter-binding rules.5.
@propertyWrapper
public struct Header<T: LosslessStringConvertible & Sendable>: Sendable {
    public let wrappedValue: T?
    public let name: String

    public init(wrappedValue: T? = nil, _ name: String) {
        self.name = name
        self.wrappedValue = wrappedValue
    }
}

/// Explicit parameter-binding wrapper: reads a query-string value into a
/// handler parameter, per the binding rules in the parameter-binding rules.5.
@propertyWrapper
public struct Query<T: LosslessStringConvertible & Sendable>: Sendable {
    public let wrappedValue: T?
    public let name: String

    public init(wrappedValue: T? = nil, _ name: String) {
        self.name = name
        self.wrappedValue = wrappedValue
    }
}

/// A file uploaded via `multipart/form-data`, streamed to a temporary file
/// as it is received, respecting `maxRequestBodySize`.
public struct UploadedFile: Sendable {
    public let fieldName: String
    public let fileName: String
    public let contentType: String?
    public let temporaryPath: String
    public let sizeInBytes: Int

    public init(fieldName: String, fileName: String, contentType: String?, temporaryPath: String, sizeInBytes: Int) {
        self.fieldName = fieldName
        self.fileName = fileName
        self.contentType = contentType
        self.temporaryPath = temporaryPath
        self.sizeInBytes = sizeInBytes
    }
}

/// A parsed `multipart/form-data` request body: flat text fields plus any
/// uploaded files. Bound into a handler parameter named/typed `Form`, per the parameter-binding rules.5.
public struct Form: Sendable {
    public let fields: [String: String]
    public let files: [UploadedFile]

    public init(fields: [String: String] = [:], files: [UploadedFile] = []) {
        self.fields = fields
        self.files = files
    }
}

// MARK: - Generated-code runtime helpers
//
// `@Controller`/`@Get` et al. (Part 2, Macro Compiler Plugin) emit calls to
// these functions from the dispatch closures they generate, rather than
// inlining conversion logic at every call site. Conversion failure always
// produces `HttpError(.badRequest)` naming the offending parameter, per the parameter-binding rules.

/// Converts a required route placeholder value, throwing `400` on failure
/// or absence.
public func bindRouteValue<T: LosslessStringConvertible>(_ raw: String?, as type: T.Type, parameterName: String) throws -> T {
    guard let raw, let value = T(raw) else {
        throw HttpError(.badRequest, "Invalid value for route parameter '\(parameterName)'")
    }
    return value
}

/// Converts an optional (`{name?}`) route placeholder value; a missing or
/// unconvertible value yields `nil` rather than a `400`.
public func bindOptionalRouteValue<T: LosslessStringConvertible>(_ raw: String?, as type: T.Type, parameterName: String) throws -> T? {
    guard let raw else { return nil }
    guard let value = T(raw) else {
        throw HttpError(.badRequest, "Invalid value for route parameter '\(parameterName)'")
    }
    return value
}

/// Converts a required query-string primitive, throwing `400` on failure or absence.
public func bindQueryValue<T: LosslessStringConvertible>(_ raw: String?, parameterName: String) throws -> T {
    guard let raw, let value = T(raw) else {
        throw HttpError(.badRequest, "Missing or invalid query parameter '\(parameterName)'")
    }
    return value
}

/// Converts an optional query-string primitive; missing or unconvertible → `nil`.
public func bindOptionalQueryValue<T: LosslessStringConvertible>(_ raw: String?) -> T? {
    guard let raw else { return nil }
    return T(raw)
}

/// Converts an optional header or query value bound via `Header<T>`/`Query<T>`;
/// missing or unconvertible → `nil` (these wrappers are always optional).
public func bindOptionalHeaderOrQueryValue<T: LosslessStringConvertible>(_ raw: String?) -> T? {
    guard let raw else { return nil }
    return T(raw)
}

/// Parses the request body as `multipart/form-data` for a `Form`-typed parameter.
///
/// - Throws: `HttpError(.badRequest)` if the body is not valid multipart
///   form data, or if it would exceed `maxRequestBodySize` while streaming
///   an uploaded file to disk (enforced by the server engine, Part 4).
public func bindForm(_ request: HttpRequest) throws -> Form {
    guard let contentType = request.headers["Content-Type"], contentType.contains("multipart/form-data") else {
        throw HttpError(.badRequest, "Expected multipart/form-data request body")
    }
    // ponytail: full multipart parsing (boundary scanning, streamed file
    // writes respecting maxRequestBodySize) belongs with the server engine's
    // body handling in Part 4, which owns the incoming byte stream this
    // function needs. This stub keeps the binding call site and its error
    // contract stable for Part 2's generated code to compile against.
    return Form()
}
