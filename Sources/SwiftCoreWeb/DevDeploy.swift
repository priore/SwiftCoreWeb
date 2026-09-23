// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

#if DEBUG
import Foundation
import os

private let devDeployLogger = Logger(subsystem: "SwiftCoreWeb", category: "server")

/// The live-reload hub: an actor broadcasting a "reload" signal to every
/// connected `/__dev/livereload` SSE client (the frontend development workflows, Mode B). Actor-isolated
/// per the concurrency/lifecycle/network watchdog design's concurrency rules for shared mutable dev-time state.
actor LiveReloadHub {
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func subscribe() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func signalReload() {
        for continuation in continuations.values {
            continuation.yield(())
        }
    }
}

/// The tiny script auto-injected into served HTML in development only
/// (the frontend development workflows), opening an `EventSource` to `/__dev/livereload` and reloading the
/// page on signal.
private let liveReloadScript = """
<script>
new EventSource('/__dev/livereload').onmessage = () => location.reload();
</script>
"""

/// Injects `liveReloadScript` just before `</body>` (or appends it if the
/// document has no closing body tag), for HTML responses only.
func injectLiveReloadScript(into html: String) -> String {
    guard let range = html.range(of: "</body>", options: [.backwards, .caseInsensitive]) else {
        return html + liveReloadScript
    }
    var result = html
    result.replaceSubrange(range, with: liveReloadScript + "</body>")
    return result
}

extension WebApplication {
    /// Adds the DEBUG-only development deploy workflow (the frontend development workflows, Mode B):
    /// `PUT /__dev/deploy` accepts a zip or multipart upload of a Vue
    /// `dist/` build, protected by a random token printed to the Xcode
    /// console, writes it atomically to `Documents/www`, and signals every
    /// connected `/__dev/livereload` client to reload. Compiled out of
    /// release builds entirely — this whole method does not exist outside
    /// `#if DEBUG`.
    @discardableResult
    public func useDevDeploy(root: ContentRoot = .documents("www")) -> Self {
        let token = UUID().uuidString
        devDeployLogger.notice("SwiftCoreWeb dev deploy token: \(token, privacy: .public) — pass it as 'X-Dev-Token' on PUT /__dev/deploy")
        let hub = LiveReloadHub()

        routeRegistry.register(method: .put, path: "/__dev/deploy", auth: .none, summary: nil) { ctx in
            guard ctx.request.headers["X-Dev-Token"] == token else {
                return Results.unauthorized()
            }
            guard let destinationRoot = resolveContentRoot(root) else {
                return Results.problem(status: .internalServerError, detail: "Could not resolve dev deploy root")
            }
            do {
                try DevDeployUnpacker.unpack(ctx.request.body, contentType: ctx.request.headers["Content-Type"], into: destinationRoot)
            } catch {
                return Results.problem(status: .badRequest, detail: "Failed to unpack deploy payload: \(error)")
            }
            await hub.signalReload()
            return Results.ok()
        }

        routeRegistry.register(method: .get, path: "/__dev/livereload", auth: .none, summary: nil) { _ in
            Results.stream(contentType: "text/event-stream; charset=utf-8") { sink in
                for await _ in await hub.subscribe() {
                    try await sink.write(SseEvent(data: "reload").encode())
                }
            }
        }

        return use { ctx, next in
            try await next()
            guard ctx.response.headers["Content-Type"]?.contains("text/html") == true,
                  case .text(let html) = ctx.response.body else { return }
            let injected = injectLiveReloadScript(into: html)
            ctx.response.body = .text(injected)
            ctx.response.headers["Content-Length"] = "\(injected.utf8.count)"
        }
    }
}

/// Unpacks a dev-deploy payload into `destinationRoot`, atomically (write to
/// a temp directory, then swap) so a partial upload never leaves the served
/// site broken mid-write.
enum DevDeployUnpacker {
    enum UnpackError: Error { case unsupportedContentType, emptyPayload }

    static func unpack(_ body: Data, contentType: String?, into destinationRoot: String) throws {
        guard !body.isEmpty else { throw UnpackError.emptyPayload }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        if let contentType, contentType.contains("multipart/form-data") {
            try MultipartFormData.writeFiles(from: body, contentType: contentType, into: tempDir)
        } else {
            // ponytail: treats the body as a flat zip and shells out to the
            // system `unzip` (present on every macOS/iOS build host and on
            // device via `Process` is unavailable on iOS, so this path is
            // exercised from Simulator/macOS dev hosts; on-device deploys use
            // the multipart form path above). Upgrade path: a pure-Swift zip
            // reader if on-device zip upload is needed.
            let zipPath = tempDir.appendingPathComponent("payload.zip")
            try body.write(to: zipPath)
            #if canImport(Darwin) && !os(iOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-oq", zipPath.path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            try fileManager.removeItem(at: zipPath)
            #else
            throw UnpackError.unsupportedContentType
            #endif
        }

        if fileManager.fileExists(atPath: destinationRoot) {
            try fileManager.removeItem(atPath: destinationRoot)
        }
        try fileManager.createDirectory(atPath: (destinationRoot as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fileManager.moveItem(atPath: tempDir.path, toPath: destinationRoot)
    }
}

/// A minimal multipart/form-data parser sufficient for the dev-deploy
/// upload: extracts each file part's filename and bytes, writes each to
/// `directory` preserving the relative path given in its filename.
enum MultipartFormData {
    static func writeFiles(from body: Data, contentType: String, into directory: URL) throws {
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            throw DevDeployUnpacker.UnpackError.unsupportedContentType
        }
        let boundary = "--" + contentType[boundaryRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let boundaryData = Data(boundary.utf8)

        var parts: [Data] = []
        var searchRange = body.startIndex..<body.endIndex
        while let range = body.range(of: boundaryData, in: searchRange) {
            if range.upperBound < body.endIndex {
                let nextSearchStart = range.upperBound
                if let nextRange = body.range(of: boundaryData, in: nextSearchStart..<body.endIndex) {
                    parts.append(body[nextSearchStart..<nextRange.lowerBound])
                }
            }
            searchRange = range.upperBound..<body.endIndex
        }

        for part in parts {
            guard let headerEndRange = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerData = part[part.startIndex..<headerEndRange.lowerBound]
            guard let headerText = String(data: headerData, encoding: .utf8),
                  let filename = extractFilename(from: headerText) else { continue }

            var fileData = part[headerEndRange.upperBound...]
            if fileData.suffix(2) == Data("\r\n".utf8) {
                fileData = fileData.dropLast(2)
            }

            let destination = directory.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: destination)
        }
    }

    private static func extractFilename(from headerText: String) -> String? {
        guard let range = headerText.range(of: "filename=\"") else { return nil }
        let rest = headerText[range.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        let filename = String(rest[rest.startIndex..<endQuote])
        return filename.isEmpty ? nil : filename
    }
}
#endif
