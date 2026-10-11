// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

final class FakeEffects: PipelineEffects, @unchecked Sendable {
    private let lock = NSLock()
    var behindCount = 3
    var conflictFiles: [String] = []
    var failingCommands: Set<String> = []
    var pushResults: [PushResult] = [.ok]
    var pipelines: [CIPipeline?] = [CIPipeline(id: 7, status: .passed)]
    var job: CIJob? = CIJob(id: 70, name: "lint")
    var fetchError: Error?
    var blockOnCommand: String?
    private(set) var calls: [String] = []
    private(set) var slept: [TimeInterval] = []
    private var pushIndex = 0
    private var pipelineIndex = 0

    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func fetch(log: @escaping LogSink) async throws {
        record("fetch")
        if let fetchError { throw fetchError }
    }
    func sha(_ ref: String) async throws -> String { ref == "origin/main" ? "base1" : "head1" }
    func behind(head: String, base: String) async throws -> Int { behindCount }
    func checkout(_ branch: String, log: @escaping LogSink) async throws { record("checkout \(branch)") }
    func rebase(onto ref: String, log: @escaping LogSink) async throws -> RebaseResult {
        record("rebase \(ref)")
        if conflictFiles.isEmpty { return .ok }
        for file in conflictFiles { log(LogLine(text: "CONFLICT (content): Merge conflict in \(file)", kind: .output)) }
        return .conflict(files: conflictFiles)
    }
    func abortRebase(log: @escaping LogSink) async { record("abort") }
    func run(_ command: String, log: @escaping LogSink) async throws -> Bool {
        record("run \(command)")
        if command == blockOnCommand { try await Task.sleep(for: .seconds(30)) }
        log(LogLine(text: failingCommands.contains(command) ? "test result: FAILED" : "test result: ok", kind: .output))
        return !failingCommands.contains(command)
    }
    func head() async throws -> String { "rebased1" }
    func push(_ branch: String, expected: String, log: @escaping LogSink) async throws -> PushResult {
        let result = lock.withLock { () -> PushResult in
            calls.append("push \(branch) \(expected)")
            defer { pushIndex += 1 }
            return pushResults[min(pushIndex, pushResults.count - 1)]
        }
        log(
            LogLine(
                text: result == .ok
                    ? "+ \(branch) -> \(branch) (forced update)" : "! [rejected] \(branch) (stale info)", kind: .output)
        )
        return result
    }
    func pipeline(sha: String) async throws -> CIPipeline? {
        lock.withLock {
            calls.append("pipeline \(sha)")
            defer { pipelineIndex += 1 }
            return pipelines[min(pipelineIndex, pipelines.count - 1)]
        }
    }
    func failedJob(pipeline: Int) async throws -> CIJob? { job }
    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { slept.append(seconds) }
        try Task.checkCancellation()
    }
}

final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)
    var step: TimeInterval = 1
    func now() -> Date {
        lock.withLock {
            value = value.addingTimeInterval(step)
            return value
        }
    }
}

struct PipelineTests {
    static let mr = MergeRequest(
        projectID: 1, iid: 101, title: "Cache API responses", author: "me", sourceBranch: "feature/api-cache",
        targetBranch: "main", webURL: URL(string: "https://x/mr/101")!, sha: "head1", draft: false, labels: [])
    static let project = Project(
        id: 1, name: "project-main", path: "g/project-main", webURL: URL(string: "https://x/g")!,
        cloneURL: URL(string: "https://x/g.git")!, defaultBranch: "main", targetBranch: "main",
        setup: "./scripts/setup.sh", test: "make test")

    final class Statuses: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [MRStatus] = []
        func add(_ status: MRStatus) { lock.withLock { if list.last != status { list.append(status) } } }
        var all: [MRStatus] { lock.withLock { list } }
    }

    func execute(_ effects: FakeEffects, project: Project = PipelineTests.project, clock: TickingClock = TickingClock())
        async -> (MRRun, [MRStatus])
    {
        let statuses = Statuses()
        let recorder = RunRecorder(MRRun()) { statuses.add($0.status) }
        let pipeline = MRPipeline(mr: Self.mr, project: project, effects: effects)
        let run = await pipeline.execute(recorder, now: { clock.now() })
        return (run, statuses.all)
    }

    func states(_ run: MRRun) -> [StageState] { run.stages.map(\.state) }

    @Test func behindGoesAllTheWayToUpToDate() async {
        let effects = FakeEffects()
        let (run, statuses) = await execute(effects)
        #expect(run.status == .upToDate(pushed: true))
        #expect(states(run) == [.done, .done, .done, .done, .done])
        #expect(
            statuses.filter { $0 != .unknown } == [
                .running(.rebase, attempt: 1), .running(.setup, attempt: 1), .running(.test, attempt: 1),
                .running(.push, attempt: 1), .running(.ci, attempt: 1), .upToDate(pushed: true),
            ])
        #expect(effects.calls.contains("push feature/api-cache head1"))
        #expect(effects.calls.contains("pipeline rebased1"))
        #expect(run.pushedSHA == "rebased1")
        #expect(run.headSHA == "head1")
        #expect(run.baseSHA == "base1")
        #expect(run[.ci].caption == .ciPassed)
        #expect(run[.rebase].duration != nil)
        #expect(run[.test].log.last?.kind == .ok)
        #expect(run.finishedAt != nil)
    }

    @Test func notBehindOnlyWatchesCI() async {
        let effects = FakeEffects()
        effects.behindCount = 0
        let (run, _) = await execute(effects)
        #expect(run.status == .upToDate(pushed: false))
        #expect(states(run) == [.skipped, .skipped, .skipped, .skipped, .done])
        #expect(run[.rebase].caption == .notNeeded)
        #expect(!effects.calls.contains { $0.hasPrefix("rebase") || $0.hasPrefix("push") || $0.hasPrefix("run") })
        #expect(effects.calls.contains("pipeline head1"))
    }

    @Test func failingTestsStopBeforePush() async {
        let effects = FakeEffects()
        effects.failingCommands = ["make test"]
        let (run, _) = await execute(effects)
        #expect(run.status == .testsFailed)
        #expect(states(run) == [.done, .done, .failed, .pending, .pending])
        #expect(!effects.calls.contains { $0.hasPrefix("push") })
        #expect(run[.test].log.last == LogLine(text: Note.notPushed.rawValue, kind: .note))
        #expect(run[.test].log.contains(LogLine(text: "$ make test", kind: .command)))
    }

    @Test func failingSetupCountsAsTestsFailed() async {
        let effects = FakeEffects()
        effects.failingCommands = ["./scripts/setup.sh"]
        let (run, _) = await execute(effects)
        #expect(run.status == .testsFailed)
        #expect(states(run) == [.done, .failed, .pending, .pending, .pending])
    }

    @Test func emptySetupIsSkipped() async {
        var project = Self.project
        project.setup = "  "
        let effects = FakeEffects()
        let (run, _) = await execute(effects, project: project)
        #expect(states(run) == [.done, .skipped, .done, .done, .done])
        #expect(effects.calls.filter { $0.hasPrefix("run") } == ["run make test"])
    }

    @Test func ciFailureNamesTheJob() async {
        let effects = FakeEffects()
        effects.pipelines = [CIPipeline(id: 7, status: .running), CIPipeline(id: 7, status: .failed)]
        let (run, _) = await execute(effects)
        #expect(run.status == .ciFailed(job: "lint"))
        #expect(states(run) == [.done, .done, .done, .done, .failed])
        #expect(run.failedJobID == 70)
        #expect(run.pipelineID == 7)
        #expect(run[.ci].detail == "lint")
        #expect(effects.slept == [10])
    }

    @Test func noPipelineMeansUpToDate() async {
        let effects = FakeEffects()
        effects.pipelines = [nil]
        let clock = TickingClock()
        clock.step = 20
        let (run, _) = await execute(effects, clock: clock)
        #expect(run.status == .upToDate(pushed: true))
        #expect(run[.ci].state == .skipped)
    }

    @Test func conflictAbortsAndLeavesBranch() async {
        let effects = FakeEffects()
        effects.conflictFiles = ["package.json", "src/config.ts"]
        let (run, _) = await execute(effects)
        #expect(run.status == .conflict(files: ["package.json", "src/config.ts"]))
        #expect(states(run) == [.failed, .pending, .pending, .pending, .pending])
        #expect(effects.calls.contains("abort"))
        #expect(!effects.calls.contains { $0.hasPrefix("run") || $0.hasPrefix("push") })
        #expect(run[.rebase].caption == .conflictFiles)
        #expect(run[.rebase].detail == "2")
        #expect(run[.rebase].log.last == LogLine(text: Note.abort.rawValue, kind: .note))
        #expect(run[.rebase].log.contains(LogLine(text: "$ git rebase --abort", kind: .command)))
    }

    @Test func rejectedPushRestartsOnceWithAttemptTwo() async {
        let effects = FakeEffects()
        effects.pushResults = [.rejected, .ok]
        let (run, statuses) = await execute(effects)
        #expect(run.status == .upToDate(pushed: true))
        #expect(run.attempt == 2)
        #expect(statuses.contains(.branchChanged))
        #expect(statuses.contains(.running(.rebase, attempt: 2)))
        #expect(effects.slept.first == 2)
        #expect(effects.calls.filter { $0 == "fetch" }.count == 2)
        #expect(states(run) == [.done, .done, .done, .done, .done])
    }

    @Test func rejectedTwiceStopsAsBranchChanged() async {
        let effects = FakeEffects()
        effects.pushResults = [.rejected]
        let (run, _) = await execute(effects)
        #expect(run.status == .branchChanged)
        #expect(run.attempt == 2)
        #expect(run[.push].state == .failed)
        #expect(run[.push].caption == .pushRejected)
        #expect(effects.calls.filter { $0.hasPrefix("push") }.count == 2)
    }

    @Test func otherPushErrorIsReported() async {
        let effects = FakeEffects()
        effects.pushResults = [.failed("remote: GitLab: You are not allowed to force push code to a protected branch")]
        let (run, _) = await execute(effects)
        #expect(
            run.status
                == .pushFailed(message: "remote: GitLab: You are not allowed to force push code to a protected branch"))
        #expect(run[.ci].state == .pending)
    }

    @Test func fetchErrorFailsRebaseStage() async {
        let effects = FakeEffects()
        effects.fetchError = GitError(command: "git fetch", status: 128, output: "fatal: unable to access")
        let (run, _) = await execute(effects)
        #expect(run.status == .error(message: "fatal: unable to access"))
        #expect(run[.rebase].state == .failed)
    }

    @Test func cancellationStopsWithoutPush() async throws {
        let effects = FakeEffects()
        effects.blockOnCommand = "make test"
        let recorder = RunRecorder(MRRun()) { _ in }
        let pipeline = MRPipeline(mr: Self.mr, project: Self.project, effects: effects)
        let task = Task { await pipeline.execute(recorder) }
        while !effects.calls.contains("run make test") { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let run = await task.value
        #expect(run.status == .running(.test, attempt: 1))
        #expect(!effects.calls.contains { $0.hasPrefix("push") })
    }
}
