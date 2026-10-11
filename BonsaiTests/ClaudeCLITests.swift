import Foundation
import Testing

@testable import Bonsai

struct ClaudeCLITests {
    func fakeClaude(_ script: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/bonsai-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("claude")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func customPathLoggedIn() async throws {
        let claude = try fakeClaude(#"echo '{"loggedIn": true, "authMethod": "claude.ai"}'"#)
        defer { try? FileManager.default.removeItem(at: claude.deletingLastPathComponent()) }
        #expect(await ClaudeCLI.check(custom: claude.path) == ClaudeCLI.Check(path: claude.path, status: .ready))
    }

    @Test func customPathNeedsLogin() async throws {
        let claude = try fakeClaude(#"echo '{"loggedIn": false}'; exit 1"#)
        defer { try? FileManager.default.removeItem(at: claude.deletingLastPathComponent()) }
        #expect(await ClaudeCLI.check(custom: claude.path).status == .needsLogin)
    }

    @Test func missingCustomPathIsNotFound() async {
        #expect(await ClaudeCLI.check(custom: "/nope/claude") == ClaudeCLI.Check(path: nil, status: .notFound))
    }

    @Test func parsesNoisyOutput() {
        #expect(ClaudeCLI.parseLoggedIn("Warning: something\n{\"loggedIn\": true}\n"))
        #expect(!ClaudeCLI.parseLoggedIn("not json"))
    }

    @Test func quoting() {
        #expect(ClaudeCLI.quote("/a b/it's") == #"'/a b/it'\''s'"#)
    }
}
