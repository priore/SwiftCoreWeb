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

/// A file uploaded via `multipart/form-data`, written to a temporary file
/// after the body is received (bounded by `maxRequestBodySize`).
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

    /// Moves the upload to `destination`, replacing any file already there.
    /// Call it from the handler: files still at `temporaryPath` are deleted once
    /// the response is produced, a moved one is not.
    public func move(to destination: URL) throws {
        let source = URL(fileURLWithPath: temporaryPath)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// The whole upload read into memory.
    public func data() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: temporaryPath))
    }
}

/// A parsed `multipart/form-data` or `application/x-www-form-urlencoded` request
/// body: flat text fields plus any uploaded files. Bound into a handler parameter named/typed `Form`, per the parameter-binding rules.5.
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

/// Temporary files created while binding a `Form`, deleted by the dispatcher
/// once the response is produced.
struct TemporaryUploads: Sendable {
    var paths: [String]
}

/// Parses the request body as `multipart/form-data` or
/// `application/x-www-form-urlencoded` for a `Form`-typed parameter. Uploaded
/// files are written to temporary files that are deleted after the response.
///
/// - Throws: `HttpError(.badRequest)` if the body is not a valid form of
///   either encoding.
public func bindForm(_ ctx: HttpContext) throws -> Form {
    let form = try parseForm(ctx.request)
    var uploads = ctx.items[TemporaryUploads.self] ?? TemporaryUploads(paths: [])
    uploads.paths += form.files.map(\.temporaryPath)
    ctx.items[TemporaryUploads.self] = uploads
    return form
}

/// Same parsing as `bindForm(_:)`, but the temporary files of uploaded parts
/// are never deleted automatically: the caller owns them.
@available(*, deprecated, message: "Use bindForm(_ ctx: HttpContext), which also deletes the uploaded temporary files after the response.")
public func bindForm(_ request: HttpRequest) throws -> Form {
    try parseForm(request)
}

// ponytail: on a buffered route the engine holds the whole body (up to the route's limit) in RAM
// before binding and the parts are written out afterwards; `spoolBodyToDisk` routes parse from the
// spooled file instead (`MultipartFileParser`), which is what large uploads need.
private func parseForm(_ request: HttpRequest) throws -> Form {
    let contentType = request.headers["Content-Type"] ?? ""
    if contentType.lowercased().hasPrefix("application/x-www-form-urlencoded") {
        return Form(fields: parseQueryString(String(decoding: try request.smallBody(), as: UTF8.self)).query)
    }
    guard contentType.lowercased().contains("multipart/form-data") else {
        throw HttpError(.badRequest, "Expected multipart/form-data or application/x-www-form-urlencoded request body")
    }
    if let bodyFile = request.bodyFile {
        return try MultipartFileParser.parse(file: bodyFile, boundary: MultipartParser.boundary(in: contentType))
    }

    var fields: [String: String] = [:]
    var files: [UploadedFile] = []
    for part in try MultipartParser.parse(request.body, boundary: MultipartParser.boundary(in: contentType)) {
        if let fileName = part.filename {
            // The client's filename is only metadata: the path on disk is never derived from it.
            let path = try UploadStorage.newFileURL()
            try part.data.write(to: path)
            files.append(UploadedFile(fieldName: part.name, fileName: fileName, contentType: part.contentType, temporaryPath: path.path, sizeInBytes: part.data.count))
        } else {
            guard let value = String(data: part.data, encoding: .utf8) else {
                throw HttpError(.badRequest, "Form field '\(part.name)' is not valid UTF-8")
            }
            fields[part.name] = value
        }
    }
    return Form(fields: fields, files: files)
}
