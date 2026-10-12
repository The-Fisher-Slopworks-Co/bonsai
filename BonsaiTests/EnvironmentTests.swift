// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct EnvironmentTests {
    static var project: Project {
        var project = PipelineTests.project
        project.environment = "nc -z localhost 5432\n\n  pg_isready  \n"
        return project
    }

    func check(_ effects: FakeEffects, project: Project = EnvironmentTests.project) async throws -> MainCheck {
        let start = MainCheck(sha: "base1", commands: MainCheck.Commands(project))
        let clock = TickingClock()
        return try await MainPipeline(project: project, effects: effects).check(
            Recorder(start) { _ in }, now: { clock.now() })
    }

    @Test func oldProjectsDecodeWithoutEnvironment() throws {
        let json = #"""
            [{"id": 7, "name": "app", "path": "g/app", "webURL": "https://x/g/app", "cloneURL": "https://x/g/app.git",
              "defaultBranch": "main", "targetBranch": "main", "setup": "", "test": "make test"}]
            """#
        let projects = try JSONDecoder().decode([Project].self, from: Data(json.utf8))
        #expect(projects.first?.environment == "")
        #expect(projects.first?.rules == "")
        #expect(projects.first?.claude == .inherit)
        #expect(projects.first?.environmentChecks == [])
    }

    @Test func environmentRunsLineByLineBeforeSetup() async throws {
        let effects = FakeEffects()
        let result = try await check(effects)
        #expect(result.phase == .passed)
        #expect(result.stages.map(\.kind) == [.ci, .checkout, .environment, .setup, .test])
        #expect(result[.environment].state == .done)
        #expect(result[.environment].detail == "nc -z localhost 5432 && pg_isready")
        #expect(result[.environment].log.first == LogLine(text: "$ nc -z localhost 5432", kind: .command))
        #expect(
            effects.calls == [
                "pipeline base1", "detach origin/main", "run nc -z localhost 5432", "run pg_isready",
                "run ./scripts/setup.sh", "run make test",
            ])
    }

    @Test func emptyEnvironmentHasNoStage() async throws {
        let result = try await check(FakeEffects(), project: PipelineTests.project)
        #expect(!result.stages.contains { $0.kind == .environment })
    }

    @Test func environmentDownMakesMainUnavailable() async throws {
        let effects = FakeEffects()
        effects.failingCommands = ["nc -z localhost 5432"]
        let result = try await check(effects)
        #expect(result.phase == .unavailable)
        #expect(result[.environment].state == .failed)
        #expect(result[.setup].state == .pending)
        #expect(result.lastPassed == nil)
        #expect(
            !effects.calls.contains { $0.hasPrefix("run ./scripts") || $0 == "run make test" || $0 == "run pg_isready" }
        )
        #expect(
            NotificationRules.mainNote(
                for: Workspace.MainChange(project: Self.project, old: .checking, new: result, mergeRequests: 2),
                settings: NotificationSettings()) == nil)
    }

    @Test func unavailableMainIsNeutral() {
        let p = MainPresentation(
            MainCheck(phase: .unavailable, sha: "base1", commands: .init(setup: "", test: "t")), branch: "main")
        #expect(p.statusText == localized("mr.unavailable"))
        #expect(p.bannerBody == localized("main.bn.unavailableBody"))
        #expect(p.actions == [.edit])
        #expect(p.tone == .secondary)
        #expect(p.group == .attention)
    }

    @Test func claudeIsNotAskedWhileEnvironmentIsDown() async {
        let effects = FakeEffects()
        effects.failingCommands = ["pg_isready"]
        var start = MainCheck(sha: "base1", commands: MainCheck.Commands(Self.project))
        start.phase = .failed
        let calls = Counter()
        let prompt = CommandPrompt(
            pick: false, branch: "main", setup: "", test: "make test", rules: "Minimal.", projectRules: "",
            language: "English")
        let result = await MainPipeline(project: Self.project, effects: effects).fix(
            prompt, attempts: 2,
            claude: { _, _, _ in
                _ = calls.next()
                return MainPipelineTests.answer(setup: "", test: "make test")
            }, Recorder(start) { _ in })
        #expect(result.phase == .unavailable)
        #expect(calls.count == 0)
        #expect(result.proposal?[.environment].state == .failed)
        #expect(result.proposal?[.claude].state == .pending)
    }

    @Test @MainActor func mergeRequestWaitsForEnvironment() async {
        let effects = FakeEffects()
        effects.failingCommands = ["pg_isready"]
        let (run, statuses) = await PipelineTests().execute(effects, project: Self.project)
        #expect(run.status == .unavailable)
        #expect(statuses.last == .unavailable)
        #expect(run.stages.map(\.kind) == [.rebase, .environment, .setup, .test, .push, .ci])
        #expect(run.stages.map(\.state) == [.done, .failed, .pending, .pending, .pending, .pending])
        #expect(!effects.calls.contains { $0.hasPrefix("push") || $0 == "run make test" })
        #expect(Workspace.fixKind(run.status) == nil)
        #expect(MRPresentation(run).statusText == localized("mr.unavailable"))
        #expect(MRPresentation(run).group != .attention)
    }

    @Test func mergeRequestNotBehindSkipsEnvironment() async {
        let effects = FakeEffects()
        effects.behindCount = 0
        let (run, _) = await PipelineTests().execute(effects, project: Self.project)
        #expect(run.status == .upToDate(pushed: false))
        #expect(run[.environment].state == .skipped)
        #expect(!effects.calls.contains { $0.hasPrefix("run") })
    }

    @Test func promptsNameTheChecks() {
        var command = CommandPrompt(
            pick: true, branch: "main", setup: "", test: "", rules: "Minimal.", projectRules: "", language: "English")
        #expect(!command.text.contains("Do not start, stop or reconfigure"))
        command.environment = Self.project.environmentChecks
        #expect(command.text.contains("Do not start, stop or reconfigure services or containers."))
        #expect(command.text.contains("```\nnc -z localhost 5432\npg_isready\n```"))

        var fix = FixPrompt(
            kind: .tests, branch: "feature", base: "origin/main", setup: "", test: "make test", rules: "Minimal.",
            projectRules: "", language: "English")
        #expect(!fix.text.contains("already running"))
        fix.environment = ["nc -z localhost 5432"]
        #expect(fix.text.contains("already running and are provided by the user"))
    }

    func environmentFixture(serviceUp: Bool) async throws -> (FixPipelineTests.Fixture, URL) {
        let base = try await FixPipelineTests().fixture(
            branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { try $0.write("CHANGELOG", "x\n") })
        let marker = base.repo.root.appendingPathComponent("service-up")
        if serviceUp { try "".write(to: marker, atomically: true, encoding: .utf8) }
        var project = base.project
        project.environment = "test -f '\(marker.path)'"
        let f = FixPipelineTests.Fixture(
            repo: base.repo, clone: base.clone, project: project, mr: base.mr, server: base.server)
        return (f, marker)
    }

    func expectEnvironmentDown(_ run: MRRun, _ f: FixPipelineTests.Fixture) {
        #expect(run.status == .unavailable)
        #expect(run.fix == nil)
        #expect(run[.environment].state == .failed)
        #expect(run[.environment].log.first?.kind == .command)
        #expect(run[.test].state == .pending)
        #expect(MRPresentation(run).statusText == localized("mr.unavailable"))
        #expect(!FileManager.default.fileExists(atPath: f.repo.root.appendingPathComponent("fixes/g/app/7").path))
    }

    @Test func fixStopsInsteadOfBlamingClaude() async throws {
        let (f, _) = try await environmentFixture(serviceUp: false)
        defer { f.repo.remove() }
        let claude = FakeClaude { _, _ in ok("Fixed.") }
        let tests = FixPipelineTests()
        let run = await tests.pipeline(f, claude: claude).fix(
            .tests, RunRecorder(tests.failedRun(.testsFailed)) { _ in })
        #expect(claude.calls.count == 0)
        expectEnvironmentDown(run, f)
    }

    @Test func fixStopsWhenEnvironmentDropsMidway() async throws {
        let (f, marker) = try await environmentFixture(serviceUp: true)
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            try "echo $(($1 + $2))\n".write(
                to: request.directory.appendingPathComponent("add.sh"), atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: marker)
            return ok("Fixed.")
        }
        let tests = FixPipelineTests()
        let run = await tests.pipeline(f, claude: claude).fix(
            .tests, RunRecorder(tests.failedRun(.testsFailed)) { _ in })
        #expect(claude.calls.count == 1)
        expectEnvironmentDown(run, f)
    }

    @Test func recheckStopsWhenEnvironmentIsDown() async throws {
        let (f, marker) = try await environmentFixture(serviceUp: true)
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            try "echo $(($1 + $2))\n".write(
                to: request.directory.appendingPathComponent("add.sh"), atomically: true, encoding: .utf8)
            return ok("Fixed.")
        }
        let tests = FixPipelineTests()
        let pipeline = tests.pipeline(f, claude: claude)
        let ready = await pipeline.fix(.tests, RunRecorder(tests.failedRun(.testsFailed)) { _ in })
        #expect(ready.fix?.phase == .ready)
        try FileManager.default.removeItem(at: marker)
        let run = await pipeline.recheck(RunRecorder(ready) { _ in })
        expectEnvironmentDown(run, f)
    }

    @Test @MainActor func savedTrimsEnvironment() {
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        model.draft.environment = "\n  nc -z localhost 5432 \n"
        #expect(model.was(.environment) == nil)
        #expect(model.saved().environment == "nc -z localhost 5432")
    }
}

@MainActor
struct WorkspaceEnvironmentTests {
    @Test func mainWaitsForEnvironmentAndChecksAgain() async throws {
        let f = try await WorkspaceTests().fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        let marker = f.repo.root.appendingPathComponent("service-up")
        var project = f.project
        project.environment = "test -f '\(marker.path)'"
        f.workspace.add(project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(project)?.phase == .unavailable)
        let mr = try #require(f.workspace.state(project).mergeRequests.first)
        #expect(f.workspace.run(mr).status == .unknown)

        try "".write(to: marker, atomically: true, encoding: .utf8)
        f.workspace.check(project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.mainCheck(project)?.phase == .passed)
        #expect(f.workspace.run(mr).status == .upToDate(pushed: true))
    }

    @Test func unavailableMergeRequestRunsAgain() throws {
        let f = WorkspaceTests()
        let store = Store(directory: f.dir, keychain: f.keychain)
        let workspace = Workspace(store: store)
        var run = MRRun()
        run.status = .unavailable
        run.headSHA = PipelineTests.mr.sha
        run.baseSHA = "base1"
        #expect(workspace.needsRun(run, mr: PipelineTests.mr, base: "base1"))
    }
}
