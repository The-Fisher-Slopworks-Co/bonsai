// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct ClaudeStreamTests {
    static var fixture: [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/claude-stream.jsonl")
        return (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    @Test func realStreamFromClaudeCode() {
        let parser = ClaudeStreamParser(cwd: "/tmp/bonsai-claude-probe")
        let events = Self.fixture.flatMap(parser.parse)
        #expect(events.first == .started(sessionID: "265cf8ec-0824-411f-9b4f-ce0936ee531b"))
        let lines = events.compactMap { if case .log(let line) = $0 { line } else { nil } }
        #expect(lines.contains(LogLine(text: "Edit  add.sh  (+1 −1)", kind: .tool)))
        #expect(lines.contains(LogLine(text: "Bash  sh test.sh", kind: .tool)))
        #expect(lines.contains(LogLine(text: "ok", kind: .ok)))
        #expect(!lines.contains { $0.text.contains("StructuredOutput") || $0.text.contains("Structured output") })
        guard case .finished(let result)? = events.last else {
            Issue.record("no result")
            return
        }
        #expect(!result.isError)
        #expect(result.sessionID == "265cf8ec-0824-411f-9b4f-ce0936ee531b")
        #expect(result.summary.contains("add.sh"))
        #expect(result.commitMessage == "Fix add() to sum its arguments instead of subtracting")
    }

    @Test func toolLines() {
        let parser = ClaudeStreamParser(cwd: "/w")
        #expect(parser.toolLine("Read", ["file_path": "/w/src/a.ts"]) == "Read  src/a.ts")
        #expect(
            parser.toolLine("Edit", ["file_path": "/w/a", "old_string": "x\ny", "new_string": ""]) == "Edit  a  (−2)")
        #expect(parser.toolLine("Bash", ["command": "cd /w && make test"]) == "Bash  make test")
        #expect(parser.toolLine("StructuredOutput", [:]) == nil)
    }

    @Test func errorResultAndNotes() {
        let parser = ClaudeStreamParser(cwd: "/w")
        let events = parser.parse(
            #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s","result":"Max turns"}"#)
        #expect(
            events == [
                .finished(
                    ClaudeResult(
                        sessionID: "s", isError: true, summary: "", commitMessage: "", notes: [:],
                        errorText: "Max turns"))
            ])
        let ok = parser.parse(
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","structured_output":{"summary":"S","commit":"","files":[{"path":"a.ts","note":"kept both"}]}}"#
        )
        guard case .finished(let result)? = ok.first else {
            Issue.record("no result")
            return
        }
        #expect(result.notes == ["a.ts": "kept both"])
        let commands = parser.parse(
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","structured_output":{"summary":"S","setup":"make deps","test":"make test"}}"#
        )
        guard case .finished(let picked)? = commands.first else {
            Issue.record("no result")
            return
        }
        #expect(picked.setup == "make deps")
        #expect(picked.test == "make test")
    }

    @Test func ignoresGarbageAndSubagents() {
        let parser = ClaudeStreamParser(cwd: "/w")
        #expect(parser.parse("not json").isEmpty)
        #expect(
            parser.parse(
                #"{"type":"assistant","parent_tool_use_id":"t1","message":{"content":[{"type":"text","text":"hi"}]}}"#
            ).isEmpty)
        #expect(
            parser.parse(
                #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Line one\n\nLine two"}]}}"#
            )
                == [.log(LogLine(text: "Line one", kind: .claude)), .log(LogLine(text: "Line two", kind: .claude))])
    }
}
