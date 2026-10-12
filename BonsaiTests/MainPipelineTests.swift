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
}
