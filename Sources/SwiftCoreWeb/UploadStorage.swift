// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation
import NIOCore

/// Where request bodies and uploaded parts are spooled: one directory, UUID-named files,
/// never named after anything the client sent.
enum UploadStorage {
    /// The uploads directory. ponytail: a task-local only so tests can observe one handler's files
    /// without racing the other tests on the shared default; production code never sets it.
    @TaskLocal static var directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCoreWeb-uploads")

    /// A fresh, not yet existing, UUID-named file URL (the directory is created if needed).
    static func newFileURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString)
    }

    /// Deletes files left behind by a crashed or killed process: anything not modified for `age` seconds.
    static func sweepStale(olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// An in-progress request body being written to disk by the server engine
/// (`spoolBodyToDisk` routes). Only the engine's connection loop touches it.
final class BodySpool {
    let url: URL
    private(set) var written = 0
    private var handle: FileHandle?

    init() throws {
        url = try UploadStorage.newFileURL()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    // ponytail: a blocking write on the connection's task; fine for a local disk, move to a
    // dedicated NIOThreadPool/NonBlockingFileIO if a slow volume ever starves other connections.
    func write(_ chunk: inout ByteBuffer) throws {
        let count = chunk.readableBytes
        guard let data = chunk.readData(length: count) else { return }
        try handle?.write(contentsOf: data)
        written += count
    }

    /// Closes the file and returns its URL; the caller owns it from here on.
    func finish() -> URL {
        try? handle?.close()
        handle = nil
        return url
    }

    /// Closes and deletes the file (413, disconnect, shutdown, error).
    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
