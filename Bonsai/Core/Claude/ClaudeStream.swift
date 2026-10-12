// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct ClaudeResult: Equatable, Sendable {
    var sessionID: String?
    var isError: Bool
    var summary: String
    var commitMessage: String
    var notes: [String: String]
    var errorText: String?
    var setup: String?
    var test: String?
}

enum ClaudeEvent: Equatable, Sendable {
    case started(sessionID: String)
    case log(LogLine)
    case finished(ClaudeResult)
}

struct ClaudeStreamParser {
    var cwd: String

    func parse(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return [] }
        switch type {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String {
                return [.started(sessionID: id)]
            }
            return []
        case "assistant":
            guard object["parent_tool_use_id"] is NSNull || object["parent_tool_use_id"] == nil else { return [] }
            return content(object).flatMap(assistantBlock)
        case "user":
            guard object["parent_tool_use_id"] is NSNull || object["parent_tool_use_id"] == nil else { return [] }
            return content(object).compactMap(toolResult)
        case "result":
            return [.finished(result(object))]
        default:
            return []
        }
    }

    private func content(_ object: [String: Any]) -> [[String: Any]] {
        ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    private func assistantBlock(_ block: [String: Any]) -> [ClaudeEvent] {
        switch block["type"] as? String {
        case "text":
            let text = block["text"] as? String ?? ""
            return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { .log(LogLine(text: $0, kind: .claude)) }
        case "tool_use":
            guard let name = block["name"] as? String,
                let line = toolLine(name, block["input"] as? [String: Any] ?? [:])
            else { return [] }
            return [.log(LogLine(text: line, kind: .tool))]
        default:
            return []
        }
    }

    func toolLine(_ name: String, _ input: [String: Any]) -> String? {
        switch name {
        case "StructuredOutput", "TodoWrite":
            return nil
        case "Bash":
            return "Bash  " + stripCd(input["command"] as? String ?? "")
        case "Read", "Write":
            return "\(name)  " + relative(input["file_path"] as? String ?? "")
        case "Edit":
            let added = lineCount(input["new_string"] as? String)
            let removed = lineCount(input["old_string"] as? String)
            return "Edit  " + relative(input["file_path"] as? String ?? "") + Self.stat(added: added, removed: removed)
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let added = edits.reduce(0) { $0 + lineCount($1["new_string"] as? String) }
            let removed = edits.reduce(0) { $0 + lineCount($1["old_string"] as? String) }
            return "Edit  " + relative(input["file_path"] as? String ?? "") + Self.stat(added: added, removed: removed)
        case "Grep", "Glob":
            return "\(name)  " + (input["pattern"] as? String ?? "")
        default:
            return name
        }
    }

    static func stat(added: Int, removed: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        return parts.isEmpty ? "" : "  (" + parts.joined(separator: " ") + ")"
    }

    private func toolResult(_ block: [String: Any]) -> ClaudeEvent? {
        guard block["type"] as? String == "tool_result" else { return nil }
        let text: String
        if let string = block["content"] as? String {
            text = string
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return nil
        }
        guard !text.hasPrefix("The file "), !text.contains("has been updated successfully"),
            !text.hasPrefix("Structured output"), !looksLikeFileListing(text)
        else { return nil }
        guard
            let last = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: {
                !$0.isEmpty
            })
        else { return nil }
        let isError = block["is_error"] as? Bool ?? false
        return .log(LogLine(text: String(last.prefix(300)), kind: isError ? .error : .ok))
    }

    private func looksLikeFileListing(_ text: String) -> Bool {
        text.split(separator: "\n").prefix(3).allSatisfy {
            $0.range(of: #"^\s*\d+[→\t]"#, options: .regularExpression) != nil
        } && !text.isEmpty
    }

    private func result(_ object: [String: Any]) -> ClaudeResult {
        let structured = object["structured_output"] as? [String: Any] ?? [:]
        var notes: [String: String] = [:]
        for file in structured["files"] as? [[String: Any]] ?? [] {
            if let path = file["path"] as? String, let note = file["note"] as? String { notes[path] = note }
        }
        let isError = (object["is_error"] as? Bool ?? false) || object["subtype"] as? String != "success"
        return ClaudeResult(
            sessionID: object["session_id"] as? String, isError: isError,
            summary: (structured["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            commitMessage: (structured["commit"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes, errorText: isError ? object["result"] as? String : nil,
            setup: structured["setup"] as? String, test: structured["test"] as? String)
    }

    private func relative(_ path: String) -> String {
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func stripCd(_ command: String) -> String {
        for candidate in ["cd \(cwd) && ", "cd '\(cwd)' && ", "cd \"\(cwd)\" && "] where command.hasPrefix(candidate) {
            return String(command.dropFirst(candidate.count))
        }
        return command
    }

    private func lineCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
