// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct ClaudeRunnerTests {
    func script(_ body: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/bonsai-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func request(_ exe: URL) -> ClaudeRequest {
        ClaudeRequest(
            executable: exe.path, directory: URL(fileURLWithPath: "/tmp"), prompt: "it's \"quoted\" `x` $HOME",
            allowedTools: ["Read", "Bash(make test)"], schema: FixPrompt.schema, resume: "s1")
    }

    @Test func passesArgumentsVerbatimAndParsesStream() async throws {
        let exe = try script(
            """
            printf '%s\\n' "$@" > "$(dirname "$0")/args"
            echo '{"type":"system","subtype":"init","session_id":"abc"}'
            echo '{"type":"result","subtype":"success","is_error":false,"session_id":"abc","structured_output":{"summary":"S","commit":"C"}}'
            """)
        defer { try? FileManager.default.removeItem(at: exe.deletingLastPathComponent()) }
        let events = EventBox()
        let result = try await LiveClaudeRunner().run(request(exe)) { events.add($0) }
        #expect(result.summary == "S")
        #expect(result.commitMessage == "C")
        #expect(events.all.first == .started(sessionID: "abc"))
        let args = try String(
            contentsOf: exe.deletingLastPathComponent().appendingPathComponent("args"), encoding: .utf8
        )
        .split(separator: "\n").map(String.init)
        #expect(args.contains("it's \"quoted\" `x` $HOME"))
        #expect(args.contains("--resume"))
        #expect(args.contains("dontAsk"))
        #expect(args.contains("Read,Bash(make test)"))
    }

    @Test func silentStartTimesOut() async throws {
        let exe = try script("sleep 30\n")
        defer { try? FileManager.default.removeItem(at: exe.deletingLastPathComponent()) }
        var runner = LiveClaudeRunner()
        runner.startTimeout = .milliseconds(500)
        let start = Date()
        await #expect(throws: ClaudeError.self) { _ = try await runner.run(request(exe)) { _ in } }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func noResultIsAnError() async throws {
        let exe = try script(
            "echo '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"abc\"}'; echo 'boom' >&2; exit 1\n")
        defer { try? FileManager.default.removeItem(at: exe.deletingLastPathComponent()) }
        await #expect(throws: ClaudeError.self) { _ = try await LiveClaudeRunner().run(request(exe)) { _ in } }
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClaudeEvent] = []
    func add(_ event: ClaudeEvent) { lock.withLock { events.append(event) } }
    var all: [ClaudeEvent] { lock.withLock { events } }
}
