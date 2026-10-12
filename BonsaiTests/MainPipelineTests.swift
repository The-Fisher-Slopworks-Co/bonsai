// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct MainPipelineTests {
    func check(
        _ effects: FakeEffects, project: Project = PipelineTests.project, lastPassed: MainCheck.Commands? = nil
    ) async throws -> MainCheck {
        let start = MainCheck(sha: "base1", commands: MainCheck.Commands(project), lastPassed: lastPassed)
        let recorder = Recorder(start) { _ in }
        let clock = TickingClock()
        return try await MainPipeline(project: project, effects: effects).check(recorder, now: { clock.now() })
    }

    @Test func passingCommandsPassAndBecomeHistory() async throws {
        let effects = FakeEffects()
        let result = try await check(effects)
        #expect(result.phase == .passed)
        #expect(result.stages.map(\.kind) == [.ci, .checkout, .setup, .test])
        #expect(result.stages.map(\.state) == [.done, .done, .done, .done])
        #expect(result[.ci].caption == .mainCiPassed)
        #expect(result[.checkout].detail == "origin/main · base1")
        #expect(result.lastPassed == MainCheck.Commands(PipelineTests.project))
        #expect(effects.calls == ["pipeline base1", "detach origin/main", "run ./scripts/setup.sh", "run make test"])
        #expect(result[.test].log.last == LogLine(text: "test result: ok", kind: .ok))
    }

    @Test func failureWithGreenCIBlamesCommands() async throws {
        let effects = FakeEffects()
        effects.failingCommands = ["make test"]
        let result = try await check(effects)
        #expect(result.phase == .failed)
        #expect(result.failedStage == .test)
        #expect(result.lastPassed == nil)
        #expect(result[.test].log.last == LogLine(text: "test result: FAILED", kind: .error))
    }

    @Test func failingSetupStopsBeforeTests() async throws {
        let effects = FakeEffects()
        effects.failingCommands = ["./scripts/setup.sh"]
        let result = try await check(effects)
        #expect(result.failedStage == .setup)
        #expect(result[.test].state == .pending)
        #expect(!effects.calls.contains("run make test"))
    }

    @Test func failureWithRedCIMeansMainIsBroken() async throws {
        let effects = FakeEffects()
        effects.pipelines = [CIPipeline(id: 4821, status: .failed)]
        effects.failingCommands = ["make test"]
        let result = try await check(effects)
        #expect(result.phase == .broken)
        #expect(result[.ci].state == .failed)
        #expect(result[.ci].caption == .mainCiFailed)
        #expect(result[.ci].log.map(\.text) == ["pipeline #4821 · main · base1", "lint: failed"])
    }

    @Test func withoutCIHistoryDecides() async throws {
        let effects = FakeEffects()
        effects.pipelines = [nil]
        effects.failingCommands = ["make test"]
        let fresh = try await check(effects)
        #expect(fresh.phase == .failed)
        #expect(fresh.stages.map(\.kind) == [.checkout, .setup, .test])

        let passedBefore = try await check(effects, lastPassed: MainCheck.Commands(PipelineTests.project))
        #expect(passedBefore.phase == .broken)

        let otherCommands = try await check(effects, lastPassed: MainCheck.Commands(setup: "", test: "npm test"))
        #expect(otherCommands.phase == .failed)
    }

    @Test func runningCIIsTreatedAsUnknown() async throws {
        let effects = FakeEffects()
        effects.pipelines = [CIPipeline(id: 1, status: .running)]
        effects.failingCommands = ["make test"]
        let result = try await check(effects, lastPassed: MainCheck.Commands(PipelineTests.project))
        #expect(result.phase == .broken)
        #expect(!result.stages.contains { $0.kind == .ci })
    }

    @Test func emptySetupIsSkipped() async throws {
        var project = PipelineTests.project
        project.setup = "  "
        let effects = FakeEffects()
        let result = try await check(effects, project: project)
        #expect(result.phase == .passed)
        #expect(result[.setup].state == .skipped)
        #expect(effects.calls == ["pipeline base1", "detach origin/main", "run make test"])
    }

    @Test func multiLineCommandsShowOnOneLine() {
        #expect(MainPipeline.oneLine("docker compose up -d\n\n  ./setup.sh ") == "docker compose up -d && ./setup.sh")
    }

    final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ prompt: String) { lock.withLock { list.append(prompt) } }
        var all: [String] { lock.withLock { list } }
    }

    static func answer(setup: String, test: String, summary: String = "Тесты: make test.") -> ClaudeResult {
        ClaudeResult(
            sessionID: "s1", isError: false, summary: summary, commitMessage: "", notes: [:], errorText: nil,
            setup: setup, test: test)
    }

    func fix(
        _ effects: FakeEffects, start: MainCheck, attempts: Int = 2,
        answer: @escaping @Sendable (Int) throws -> ClaudeResult
    ) async -> (MainCheck, [String]) {
        let prompts = Prompts()
        let counter = Counter()
        let prompt = CommandPrompt(
            pick: start.pick, branch: "main", setup: start.commands.setup, test: start.commands.test,
            failureLog: "ECONNREFUSED", rules: "Minimal.", projectRules: "", language: "English")
        let clock = TickingClock()
        let result = await MainPipeline(project: PipelineTests.project, effects: effects).fix(
            prompt, attempts: attempts,
            claude: { text, _, onEvent in
                prompts.add(text)
                onEvent(.log(LogLine(text: "Read  Makefile", kind: .tool)))
                return try answer(counter.next())
            }, Recorder(start) { _ in }, now: { clock.now() })
        return (result, prompts.all)
    }

    static let empty = MainCheck(sha: "base1", commands: MainCheck.Commands(setup: "", test: ""), pick: true)

    @Test func pickedCommandsAreVerifiedOnMain() async {
        let effects = FakeEffects()
        let (result, prompts) = await fix(effects, start: Self.empty) { _ in
            Self.answer(setup: "docker compose up -d\n./scripts/setup.sh", test: "make test")
        }
        #expect(result.phase == .ready)
        #expect(
            result.proposal?.commands
                == MainCheck.Commands(setup: "docker compose up -d\n./scripts/setup.sh", test: "make test"))
        #expect(result.proposal?.summary == "Тесты: make test.")
        #expect(result.proposal?.stages.map(\.kind) == [.pick, .setup, .test])
        #expect(result.proposal?.stages.map(\.state) == [.done, .done, .done])
        #expect(result.proposal?[.pick].caption == .commandsChanged)
        #expect(result.proposal?[.pick].detail == "1/1/3")
        #expect(result.proposal?[.pick].log.first?.text == "Read  Makefile")
        #expect(result.proposal?[.setup].detail == "docker compose up -d && ./scripts/setup.sh")
        #expect(result.proposal?[.test].caption == .command)
        #expect(prompts.count == 1 && prompts[0].contains("no commands yet"))
        #expect(
            effects.calls == [
                "detach origin/main", "detach origin/main", "run docker compose up -d\n./scripts/setup.sh",
                "run make test",
            ])
    }

    @Test func failingProposalIsRetriedWithItsOutput() async {
        let effects = FakeEffects()
        effects.failingCommands = ["npm test"]
        var start = MainCheck(
            sha: "base1", commands: MainCheck.Commands(setup: "./scripts/setup.sh", test: "make check"))
        start.phase = .failed
        let (result, prompts) = await fix(effects, start: start) { n in
            Self.answer(setup: "./scripts/setup.sh", test: n == 1 ? "npm test" : "make test")
        }
        #expect(result.phase == .ready)
        #expect(result.proposal?[.claude].detail == "0/1/1")
        #expect(result.proposal?[.test].caption == .afterFix)
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("ECONNREFUSED"))
        #expect(prompts[1].contains("test result: FAILED"))
    }

    @Test func givingUpReturnsToTheFailure() async {
        let effects = FakeEffects()
        effects.failingCommands = ["make test"]
        var start = MainCheck(sha: "base1", commands: MainCheck.Commands(PipelineTests.project))
        start.phase = .failed
        let (failed, _) = await fix(effects, start: start) { _ in Self.answer(setup: "", test: "make test") }
        #expect(failed.phase == .failed)
        #expect(failed.proposal?[.claude].state == .failed)
        #expect(failed.proposal?[.claude].caption == .claudeFailed)

        let (missing, _) = await fix(FakeEffects(), start: Self.empty) { _ in
            throw ClaudeError(message: "claude exited with 1")
        }
        #expect(missing.phase == .missing)
        #expect(missing.proposal?[.pick].log.last == LogLine(text: "claude exited with 1", kind: .error))
    }

    @Test func emptyTestCommandIsNotAccepted() async {
        let (result, prompts) = await fix(FakeEffects(), start: Self.empty, attempts: 1) { _ in
            Self.answer(setup: "make deps", test: " ")
        }
        #expect(result.phase == .missing)
        #expect(prompts.count == 1)
    }

    @Test func stoppingDropsTheProposal() async {
        let task = Task {
            await fix(FakeEffects(), start: Self.empty) { _ in throw CancellationError() }
        }
        let (result, _) = await task.value
        #expect(result.phase == .stopped)
        #expect(result.proposal == nil)
    }

    @Test func changesCountAddedLines() {
        let old = MainCheck.Commands(setup: "./scripts/setup.sh", test: "make test")
        let new = MainCheck.Commands(setup: "docker compose up -d postgres\n./scripts/setup.sh", test: "make test")
        #expect(MainPipeline.changes(from: old, to: new) == "1/0/1")
    }
}
