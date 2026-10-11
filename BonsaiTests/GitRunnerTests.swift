// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct GitRunnerTests {
    @Test func cloneFetchAndBehind() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clones/group/app"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        #expect(clone.isRepository)
        #expect(try await clone.currentBranch() == "main")
        #expect(try await clone.isClean)

        try await repo.sh("git checkout -q -b feature", in: repo.seed)
        try repo.write("f.txt", "f\n")
        try await repo.commit("feature")
        try await repo.sh("git push -q origin feature && git checkout -q main", in: repo.seed)
        for i in 1...3 {
            try repo.write("m\(i).txt", "\(i)\n")
            try await repo.commit("main \(i)")
        }
        try await repo.sh("git push -q origin main", in: repo.seed)

        try await clone.fetch()
        #expect(try await clone.behind("origin/feature", base: "origin/main") == 3)
        #expect(try await clone.behind("origin/main", base: "origin/feature") == 1)
        let sha = try await clone.revParse("origin/main")
        #expect(sha.count == 40)
    }

    @Test func failedCloneLeavesNoFolder() async throws {
        let root = URL(fileURLWithPath: "/tmp/bonsai-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = GitRunner(directory: root.appendingPathComponent("x/app"))
        await #expect(throws: GitError.self) { try await clone.clone(root.appendingPathComponent("missing.git")) }
        #expect(!FileManager.default.fileExists(atPath: clone.directory.path))
    }

    @Test func checkedThrowsWithOutput() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let git = GitRunner(directory: repo.seed)
        do {
            try await git.checked(["rev-parse", "--verify", "nope"])
            Issue.record("expected failure")
        } catch let error as GitError {
            #expect(error.status != 0)
        }
    }

    @Test func authGoesThroughEnvironmentOnly() {
        let auth = GitAuth(
            token: "glpat-x", caFile: URL(fileURLWithPath: "/tmp/ca.pem"), server: URL(string: "https://git.corp"))
        let env = auth.environment
        #expect(env["GIT_CONFIG_COUNT"] == "2")
        #expect(env["GIT_CONFIG_KEY_0"] == "http.extraHeader")
        #expect(
            env["GIT_CONFIG_VALUE_0"] == "Authorization: Basic " + Data("oauth2:glpat-x".utf8).base64EncodedString())
        #expect(env["GIT_CONFIG_KEY_1"] == "http.https://git.corp/.sslCAInfo")
    }

    @Test func commitsWithIdentityAndIgnoresGlobalConfig() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let git = GitRunner(
            directory: repo.seed, identity: GitIdentity(name: "Bonsai User", email: "bonsai@example.com"))
        #expect(
            try await git.run(["config", "--global", "--list"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
        try repo.write("b.txt", "b\n")
        try await git.checked(["add", "-A"])
        try await git.checked(["commit", "-q", "-m", "b"])
        #expect(
            try await git.checked(["log", "-1", "--format=%an <%ae>|%cn <%ce>"])
                == "Bonsai User <bonsai@example.com>|Bonsai User <bonsai@example.com>")
    }

    @Test func emptyIdentityFieldsAreNotExported() {
        let env = GitRunner(directory: URL(fileURLWithPath: "/tmp"), identity: GitIdentity(name: "N", email: ""))
            .environment
        #expect(env["GIT_AUTHOR_NAME"] == "N")
        #expect(env["GIT_COMMITTER_NAME"] == "N")
        #expect(env["GIT_AUTHOR_EMAIL"] == nil)
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1")
    }
}

struct ProcessRunnerTests {
    @Test func capturesMergedOutputAndStatus() async throws {
        let lines = Lines()
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo one; echo two >&2; exit 3"]) { lines.add($0) }
        #expect(result.status == 3)
        #expect(result.output.contains("one"))
        #expect(result.output.contains("two"))
        #expect(lines.all == ["one", "two"])
    }

    @Test func runsInDirectoryWithEnvironment() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "pwd; echo $BONSAI_X"], in: URL(fileURLWithPath: "/tmp"), environment: ["BONSAI_X": "42"])
        #expect(result.output.contains("/tmp"))
        #expect(result.output.contains("42"))
    }

    @Test func cancelKillsProcessGroup() async throws {
        let marker = "/tmp/bonsai-cancel-\(UUID().uuidString)"
        let task = Task {
            try await ProcessRunner.run("/bin/sh", ["-c", "(sleep 30; touch \(marker)) & sleep 30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        _ = await task.result
        #expect(Date().timeIntervalSince(start) < 5)
        let check = try await ProcessRunner.run("/bin/sh", ["-c", "pgrep -f '\(marker)' || true"])
        #expect(check.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: ProcessRunner.LaunchError.self) { try await ProcessRunner.run("/nope/nothing", []) }
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

struct ProcessSignalTests {
    @Test func childStartsWithEmptySignalMask() async throws {
        let result = try await Task.detached {
            try await ProcessRunner.run(
                "/bin/sh", ["-c", "grep -E '^Sig(Blk|Ign)' /proc/self/status 2>/dev/null || ps -o sigmask= -p $$"])
        }.value
        let mask = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mask == "0" || mask.allSatisfy { $0 == "0" } || mask.hasSuffix("00000000"), "mask: \(mask)")
    }
}
