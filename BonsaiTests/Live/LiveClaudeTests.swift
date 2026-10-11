// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BONSAI_LIVE_CLAUDE"] == "1" && LiveGitLab.isAvailable))
struct LiveClaudeTests {
    @Test(.timeLimit(.minutes(10)))
    func fixFailingTestAndConflict() async throws {
        let check = await ClaudeCLI.check(custom: nil)
        let claudePath = try #require(check.path)
        #expect(check.status == .ready)
        let name = "e2e-claude-\(UUID().uuidString.prefix(6).lowercased())"
        let id = try await LiveGitLab.seed(name)
        let root = URL(fileURLWithPath: "/tmp/bonsai-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await LiveGitLab.project(id)
        let gitlab = LiveGitLab.client()
        let auth = GitAuth(token: try #require(LiveGitLab.token), caFile: nil, server: LiveGitLab.server)
        let clone = GitRunner(directory: root.appendingPathComponent("clone"), auth: auth)
        try await clone.clone(project.cloneURL)
        let mrs = try await gitlab.mergeRequests(project: id, scope: .mine)
        let runner = LiveClaudeRunner(extraArguments: ["--model", "sonnet", "--effort", "low"])
        var config = FixPipeline.Config()
        config.attempts = 2
        config.ciPollInterval = 3

        let failing = try #require(mrs.first { $0.sourceBranch == "feature/failing-test" })
        let failedRun = await MRPipeline(
            mr: failing, project: project, effects: LivePipelineEffects(git: clone, gitlab: gitlab, projectID: id)
        )
        .execute(RunRecorder(MRRun()) { _ in })
        #expect(failedRun.status == .testsFailed)
        let effects = LiveFixEffects(
            clone: clone, worktree: root.appendingPathComponent("fixes/tests"), gitlab: gitlab, projectID: id,
            claudePath: claudePath, runner: runner)
        let fixer = FixPipeline(
            mr: failing, project: project, effects: effects, rules: localized("settings.rulesDefault"), config: config)
        let recorder = RunRecorder(failedRun) { _ in }
        let fixed = await fixer.fix(.tests, recorder)
        let fix = try #require(fixed.fix)
        print(
            "LIVE tests fix:", fix.phase, fix.summary, "|", fix.commitMessage, fix.files.map(\.path),
            fix[.claude].log.map(\.text))
        #expect(fix.phase == .ready)
        #expect(fix.sessionID != nil)
        #expect(!fix.summary.isEmpty)
        #expect(!fix.commitMessage.isEmpty)
        #expect(fix.files.map(\.path).contains("src/add.sh"))
        #expect(fix[.claude].log.contains { $0.kind == .tool })
        let pushed = await fixer.push(message: fix.commitMessage, recorder)
        #expect(pushed.fix?.phase == .pushed)
        #expect(pushed.status == .upToDate(pushed: true))

        let conflictMR = try #require(mrs.first { $0.sourceBranch == "feature/conflict" })
        let conflictRun = await MRPipeline(
            mr: conflictMR, project: project, effects: LivePipelineEffects(git: clone, gitlab: gitlab, projectID: id)
        )
        .execute(RunRecorder(MRRun()) { _ in })
        #expect(conflictRun.status == .conflict(files: ["README.md"]))
        let conflictEffects = LiveFixEffects(
            clone: clone, worktree: root.appendingPathComponent("fixes/conflict"), gitlab: gitlab, projectID: id,
            claudePath: claudePath, runner: runner)
        let conflictFixer = FixPipeline(
            mr: conflictMR, project: project, effects: conflictEffects, rules: localized("settings.rulesDefault"),
            config: config)
        let resolved = await conflictFixer.fix(.conflict, RunRecorder(conflictRun) { _ in })
        let conflictFix = try #require(resolved.fix)
        print(
            "LIVE conflict fix:", conflictFix.phase, conflictFix.summary,
            conflictFix.files.map { ($0.path, $0.conflicts.map(\.source)) },
            conflictFix[.claude].log.map(\.text))
        #expect(conflictFix.phase == .ready)
        #expect(conflictFix.files.first?.path == "README.md")
        #expect(conflictFix[.continueRebase].state == .done)
        await conflictEffects.discard()
        await LiveGitLab.deleteProject(id)
    }
}
