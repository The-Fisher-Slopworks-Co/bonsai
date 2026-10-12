// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct LocalCopyError: LocalizedError, Equatable {
    var path: String
    var outside = false

    var errorDescription: String? {
        outside ? "cp: \(path): outside the checkout" : localized("localCopy.missing", path)
    }
}

extension GitRunner {
    func copy(_ paths: [String], from localCopy: String, log: @escaping LogSink) async throws {
        let local = URL(fileURLWithPath: (localCopy as NSString).expandingTildeInPath)
        let source = Self.resolved(local)
        let root = Self.resolved(directory)
        var pairs: [(path: String, from: URL, to: URL)] = []
        for path in paths {
            let from = Self.resolved(source.appendingPathComponent(path), keepingLast: true)
            let to = Self.resolved(root.appendingPathComponent(path), keepingLast: true)
            guard Self.isInside(from, source), Self.isInside(to, root) else {
                throw LocalCopyError(path: path, outside: true)
            }
            guard FileManager.default.fileExists(atPath: from.path) else { throw LocalCopyError(path: path) }
            pairs.append((path, from, to))
        }
        try await writeExcludes(nil)
        var excluded: [String] = []
        for (path, from, to) in pairs {
            let shown = local.appendingPathComponent(path).path
            log(LogLine(text: "$ cp -c -R \(shown) \(path)", kind: .command))
            do {
                try FileManager.default.removeItem(at: to)
            } catch CocoaError.fileNoSuchFile {}
            try FileManager.default.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try await ProcessRunner.run(
                "/bin/cp", ["-c", "-R", from.path, to.path], in: directory,
                onLine: { log(LogLine(text: $0, kind: .output)) })
            guard result.succeeded else {
                throw GitError(command: "cp -c -R \(shown) \(path)", status: result.status, output: result.output)
            }
            let literal = ":(literal)\(path)"
            let tracked = try await checked(["ls-files", "-z", "--", literal]).split(separator: "\0")
            guard !tracked.isEmpty else {
                excluded.append(path)
                continue
            }
            try await checked(
                ["update-index", "--skip-worktree", "-z", "--stdin"], input: Data(tracked.joined(separator: "\0").utf8))
            excluded += try await checked([
                "ls-files", "-z", "--others", "--directory", "--exclude-standard", "--", literal,
            ])
            .split(separator: "\0").map(String.init)
        }
        try await writeExcludes(excluded)
    }

    func restoreCopied() async throws {
        let skipped = try await checked(["ls-files", "-v", "-z"]).split(separator: "\0")
            .filter { $0.hasPrefix("S ") }.map { $0.dropFirst(2) }
        guard !skipped.isEmpty else { return }
        try await checked(
            ["update-index", "--no-skip-worktree", "-z", "--stdin"], input: Data(skipped.joined(separator: "\0").utf8))
    }

    private static let excludeStart = "# bonsai local copy"
    private static let excludeEnd = "# end bonsai local copy"

    private func writeExcludes(_ paths: [String]?) async throws {
        let path = try await checked(["rev-parse", "--git-path", "info/exclude"])
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines: [String] = []
        var inBlock = false
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            switch line {
            case Self.excludeStart: inBlock = true
            case Self.excludeEnd: inBlock = false
            default: if !inBlock { lines.append(line) }
            }
        }
        while lines.last == "" { lines.removeLast() }
        if let paths, !paths.isEmpty {
            lines += [Self.excludeStart] + paths.map(Self.pattern) + [Self.excludeEnd]
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        guard text != existing else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func pattern(_ path: String) -> String {
        "/" + path.replacing(/[\\*?\[]/) { "\\" + $0.output }
    }

    private static func resolved(_ url: URL, keepingLast: Bool = false) -> URL {
        var base = url.standardizedFileURL
        var rest: [String] = []
        if keepingLast {
            rest.append(base.lastPathComponent)
            base.deleteLastPathComponent()
        }
        while base.path != "/" && !FileManager.default.fileExists(atPath: base.path) {
            rest.insert(base.lastPathComponent, at: 0)
            base.deleteLastPathComponent()
        }
        return rest.reduce(base.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let parts = url.pathComponents
        let rootParts = root.pathComponents
        return parts.count > rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
            && parts[rootParts.count] != ".git"
    }
}
