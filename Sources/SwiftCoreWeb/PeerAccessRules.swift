// SwiftCoreWeb
// Copyright (c) 2026 SwiftCoreWeb contributors.
// Licensed under the PolyForm Noncommercial License 1.0.0.
// Free for noncommercial use; commercial use requires a separate license from the author.
// See LICENSE at the repository root. Source-available, not open-source.
//

import Foundation

/// Which paths a request that arrives through an extension's peer listener (see `ServerExtension`) may reach. Requests
/// on the normal listeners are never affected. The most specific (longest) matching prefix wins; paths no rule names
/// follow `defaultAllowed`; among rules of the same length the one set last wins. A `{placeholder}` segment matches any
/// single segment whatever its constraint, and a rule on `/` (no segments) covers every path. A denied path is answered
/// like a path that matches nothing.
final class PeerAccessRules: @unchecked Sendable {
    private let lock = NSLock()
    private var defaultAllowed = true
    private var rules: [(segments: [Substring], allowed: Bool)] = []

    func setDefault(_ allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        defaultAllowed = allowed
    }

    /// `prefix` matches a path equal to it or below it, segment by segment; a `{placeholder}` segment matches any segment.
    func set(prefix: String, allowed: Bool) {
        let segments = prefix.split(separator: "/")
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { $0.segments == segments }
        rules.append((segments, allowed))
    }

    /// A path with a `.` or `..` segment is never allowed: static files normalize it, so it could name a hidden file. Both the
    /// path as sent and its percent-decoded form must be allowed, and segments compare without regard to case (a
    /// case-insensitive volume serves `/PRIVATE` for `/private`).
    func allows(path: String) -> Bool {
        let forms = [path] + (path.removingPercentEncoding.map { $0 == path ? [] : [$0] } ?? [])
        return forms.allSatisfy(allowsLiteral)
    }

    private func allowsLiteral(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        lock.lock(); defer { lock.unlock() }
        var best: (length: Int, allowed: Bool)?
        for rule in rules where rule.segments.count <= parts.count {
            let matches = zip(rule.segments, parts).allSatisfy { ruleSegment, part in
                ruleSegment.lowercased() == part.lowercased() || (ruleSegment.hasPrefix("{") && ruleSegment.hasSuffix("}"))
            }
            if matches, rule.segments.count >= (best?.length ?? -1) { best = (rule.segments.count, rule.allowed) }
        }
        return best?.allowed ?? defaultAllowed
    }
}
