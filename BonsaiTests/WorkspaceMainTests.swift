// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

@MainActor
struct WorkspaceMainTests {
    func fixture(test: String, claude: FakeClaude?) async throws -> WorkspaceTests.Fixture {
        let f = try await WorkspaceTests().fixture(test: test)
        if let claude {
            f.workspace.claude = ClaudeCLI.Check(path: "/usr/bin/true", status: .ready)
            f.workspace.makeClaudeRunner = { claude }
        }
        return f
    }

    static let picking = FakeClaude { request, _ in
        #expect(request.allowedTools == CommandPrompt.allowedTools)
        try "x\n".write(to: request.directory.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        return MainPipelineTests.answer(setup: "", test: "[ ! -f stray.txt ]")
    }

    func project(_ f: WorkspaceTests.Fixture) -> Project {
        f.store.projects.first { $0.id == f.project.id } ?? f.project
    }

    @Test func claudePicksCommandsAndApplyStartsMergeRequests() async throws {
        let f = try await fixture(test: "", claude: Self.picking)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        let check = try #require(f.workspace.mainCheck(f.project))
        #expect(check.phase == .ready)
        #expect(check.pick)
        #expect(check.proposal?.commands?.test == "[ ! -f stray.txt ]")
        let mr = try #require(f.workspace.state(f.project).mergeRequests.first)
        #expect(f.workspace.run(mr).status == .unknown)

        f.workspace.check(f.project, recheck: true)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(f.project)?.phase == .ready)

        f.workspace.applyMain(project(f))
        await f.workspace.waitUntilIdle()
        #expect(project(f).test == "[ ! -f stray.txt ]")
        #expect(f.workspace.mainCheck(f.project)?.phase == .passed)
        #expect(f.workspace.run(mr).status == .upToDate(pushed: true))
    }

    @Test func rejectingKeepsMergeRequestsWaiting() async throws {
        let f = try await fixture(test: "", claude: Self.picking)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        f.workspace.rejectMain(project(f))
        #expect(f.workspace.mainCheck(f.project)?.phase == .rejected)
        #expect(f.workspace.mainCheck(f.project)?.proposal == nil)
        f.workspace.check(f.project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(f.project)?.phase == .rejected)
        #expect(project(f).test.isEmpty)
    }

    @Test func fixIsOnlyByButtonAndChangesOnlyCommands() async throws {
        let claude = FakeClaude { _, _ in MainPipelineTests.answer(setup: "", test: "true") }
        let f = try await fixture(test: "exit 1", claude: claude)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(f.project)?.phase == .failed)
        #expect(claude.calls.count == 0)

        f.workspace.fixMain(project(f))
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(f.project)?.phase == .ready)
        #expect(f.workspace.mainCheck(f.project)?.proposal?[.claude].state == .done)
        #expect(project(f).test == "exit 1")
    }

    @Test func withoutClaudeCommandsComeFromTheMakefile() async throws {
        let f = try await fixture(test: "", claude: nil)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        try f.repo.write("Makefile", "test:\n\ttrue\n")
        try await f.repo.commit("add makefile")
        try await f.repo.sh("git push -q origin main", in: f.repo.seed)
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        #expect(project(f).test == "make test")
        #expect(f.workspace.mainCheck(f.project)?.phase == .passed)
    }

    @Test func withoutClaudeOrKnownFilesCommandsAreMissing() async throws {
        let f = try await fixture(test: "", claude: nil)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(f.project)?.phase == .missing)
        #expect(f.workspace.isWaiting(f.project))
    }

    struct SlowClaude: ClaudeRunning {
        func run(_ request: ClaudeRequest, onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws
            -> ClaudeResult
        {
            onEvent(.log(LogLine(text: "Read  Makefile", kind: .tool)))
            try await Task.sleep(for: .seconds(30))
            return MainPipelineTests.answer(setup: "", test: "true")
        }
    }

    @Test func stoppingClaudeLeavesMergeRequestsWaiting() async throws {
        let f = try await WorkspaceTests().fixture(test: "")
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.claude = ClaudeCLI.Check(path: "/usr/bin/true", status: .ready)
        f.workspace.makeClaudeRunner = { SlowClaude() }
        f.workspace.add(f.project)
        for _ in 0..<200 where f.workspace.mainCheck(f.project)?.proposal?[.pick].log.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(f.workspace.mainCheck(f.project)?.phase == .fixing)
        #expect(!f.workspace.canFixMain(project(f)))
        f.workspace.stopMain(project(f))
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(f.project)?.phase == .stopped)
        #expect(f.workspace.canFixMain(project(f)))
    }
}
