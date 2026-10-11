// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

enum ClaudeCLI {
    enum Status: Equatable, Sendable {
        case ready, notFound, needsLogin
    }

    struct Check: Equatable, Sendable {
        var path: String?
        var status: Status
    }

    static var typicalPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    static func locate(custom: String?, shell: String = "/bin/zsh") async -> String? {
        let fm = FileManager.default
        if let custom, !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        if let result = try? await ProcessRunner.run(shell, ["-lc", "command -v claude"]), result.succeeded {
            let path = result.output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { return path }
        }
        return typicalPaths.first { fm.isExecutableFile(atPath: $0) }
    }

    static func isLoggedIn(_ path: String, shell: String = "/bin/zsh") async -> Bool {
        guard let result = try? await ProcessRunner.run(shell, ["-lc", "\(quote(path)) auth status --json"]) else {
            return false
        }
        return parseLoggedIn(result.output)
    }

    static func parseLoggedIn(_ output: String) -> Bool {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
            let data = String(output[start...end]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["loggedIn"] as? Bool ?? false
    }

    static func check(custom: String?) async -> Check {
        guard let path = await locate(custom: custom) else { return Check(path: nil, status: .notFound) }
        return Check(path: path, status: await isLoggedIn(path) ? .ready : .needsLogin)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
