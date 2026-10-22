// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import SwiftCoreWebTesting
@testable import SwiftCoreWeb

/// Shared helpers of the binary transfer / blob / Live Pages upload tests.
enum TransferSupport {
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static func multipart(boundary: String = "XyZ", fields: [(String, String)] = [], files: [(name: String, fileName: String, contentType: String, data: Data)] = []) -> (body: Data, contentType: String) {
        var body = Data()
        for (name, value) in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        for file in files {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\nContent-Type: \(file.contentType)\r\n\r\n".utf8)
            body += file.data + Data("\r\n".utf8)
        }
        body += Data("--\(boundary)--\r\n".utf8)
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// The value of cookie `name` set by the response.
    static func cookie(_ name: String, in response: TestResponse) -> String? {
        response.headers.values(for: "Set-Cookie").first { $0.hasPrefix("\(name)=") }
            .map { String($0.dropFirst(name.count + 1).prefix { $0 != ";" }) }
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
