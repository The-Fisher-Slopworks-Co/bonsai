// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

enum Note: String, Sendable {
    case abort, notPushed, restart, notNeeded, ciPassed
}

protocol Recordable: Sendable {
    mutating func append(_ line: LogLine, to kind: StageKind, fix: Bool)
}

typealias RunRecorder = Recorder<MRRun>

final class Recorder<Value: Recordable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private var revision = 0
    private let emit: @Sendable (Value, Int) -> Void
    private var flushScheduled = false

    convenience init(_ run: Value, emit: @escaping @Sendable (Value) -> Void) {
        self.init(run) { run, _ in emit(run) }
    }

    init(_ run: Value, emit: @escaping @Sendable (Value, Int) -> Void) {
        current = run
        self.emit = emit
    }

    var run: Value { lock.withLock { current } }

    func update(_ change: (inout Value) -> Void) {
        let (snapshot, number) = lock.withLock { () -> (Value, Int) in
            change(&current)
            revision += 1
            return (current, revision)
        }
        emit(snapshot, number)
    }

    func log(_ kind: StageKind) -> LogSink {
        { [weak self] line in self?.append(line, to: kind) }
    }

    func fixLog(_ kind: StageKind) -> LogSink {
        { [weak self] line in self?.append(line, to: kind, fix: true) }
    }

    func append(_ line: LogLine, to kind: StageKind, fix: Bool = false) {
        let schedule = lock.withLock { () -> Bool in
            current.append(line, to: kind, fix: fix)
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let (snapshot, number) = self.lock.withLock { () -> (Value, Int) in
                self.flushScheduled = false
                self.revision += 1
                return (self.current, self.revision)
            }
            self.emit(snapshot, number)
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    func callAsFunction() {
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { action = nil }
            return action
        }
        pending?()
    }
}

struct MRPipeline: Sendable {
    struct Config: Sendable {
        var maxAttempts = 2
        var restartDelay: TimeInterval = 2
        var ciPollInterval: TimeInterval = 10
        var ciAppearTimeout: TimeInterval = 90
        var ciTimeout: TimeInterval = 3 * 3600
    }

    var mr: MergeRequest
    var project: Project
    var effects: any PipelineEffects
    var config = Config()

    private var source: String { mr.sourceBranch }
    private var target: String { project.targetBranch }

    func execute(
        _ recorder: RunRecorder, now: @Sendable () -> Date = Date.init,
        onLocalDone: @escaping @Sendable () -> Void = {}
    ) async -> MRRun {
        let release = Once(onLocalDone)
        defer { release() }
        var attempt = 1
        while true {
            do {
                switch try await attemptOnce(attempt, recorder, now: now, release: release) {
                case .finished:
                    return recorder.run
                case .restart:
                    attempt += 1
                }
            } catch is CancellationError {
                return recorder.run
            } catch {
                fail(recorder, error: error, now: now)
                return recorder.run
            }
        }
    }

    private enum Outcome { case finished, restart }

    func watchCIOnly(_ recorder: RunRecorder, sha: String, pushed: Bool, now: @Sendable () -> Date = Date.init) async
        -> MRRun
    {
        do {
            _ = try await watchCI(sha: sha, pushed: pushed, recorder, attempt: recorder.run.attempt, now: now)
        } catch is CancellationError {
        } catch {
            fail(recorder, error: error, now: now)
        }
        return recorder.run
    }

    private func attemptOnce(_ attempt: Int, _ recorder: RunRecorder, now: @Sendable () -> Date, release: Once)
        async throws -> Outcome
    {
        recorder.update { run in
            run.attempt = attempt
            run.resetStages()
            run.pushedSHA = nil
            run.pipelineID = nil
            run.failedJobID = nil
            run.finishedAt = nil
            run[.rebase].caption = .onto
            run[.rebase].detail = "origin/\(target)"
        }

        start(.rebase, recorder, attempt: attempt, now: now)
        let rebaseLog = recorder.log(.rebase)
        rebaseLog(LogLine(text: "$ git fetch origin \(target)", kind: .command))
        try await effects.fetch(log: rebaseLog)
        let head = try await effects.sha("origin/\(source)")
        let base = try await effects.sha("origin/\(target)")
        recorder.update {
            $0.headSHA = head
            $0.baseSHA = base
        }
        let behind = try await effects.behind(head: "origin/\(source)", base: "origin/\(target)")

        if behind == 0 {
            rebaseLog(LogLine(text: "$ git merge-base --is-ancestor origin/\(target) origin/\(source)", kind: .command))
            rebaseLog(LogLine(text: Note.notNeeded.rawValue, kind: .note))
            finish(.rebase, .skipped, recorder, now: now) { $0.caption = .notNeeded }
            for kind in [StageKind.setup, .test, .push] {
                recorder.update {
                    $0[kind].state = .skipped
                    $0[kind].caption = .none
                }
            }
            release()
            return try await watchCI(sha: head, pushed: false, recorder, attempt: attempt, now: now)
        }

        try await effects.checkout(source, log: rebaseLog)
        rebaseLog(LogLine(text: "$ git rebase origin/\(target)", kind: .command))
        switch try await effects.rebase(onto: "origin/\(target)", log: rebaseLog) {
        case .conflict(let files):
            rebaseLog(LogLine(text: "$ git rebase --abort", kind: .command))
            await effects.abortRebase(log: rebaseLog)
            rebaseLog(LogLine(text: Note.abort.rawValue, kind: .note))
            finish(.rebase, .failed, recorder, now: now) {
                $0.caption = .conflictFiles
                $0.detail = String(files.count)
            }
            recorder.update {
                $0.status = .conflict(files: files)
                $0.finishedAt = now()
            }
            return .finished
        case .ok:
            finish(.rebase, .done, recorder, now: now)
        }

        for (kind, command) in [(StageKind.setup, project.setup), (.test, project.test)] {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                recorder.update {
                    $0[kind].state = .skipped
                    $0[kind].caption = .none
                }
                continue
            }
            recorder.update {
                $0[kind].caption = .command
                $0[kind].detail = firstLine(trimmed)
            }
            start(kind, recorder, attempt: attempt, now: now)
            let log = recorder.log(kind)
            for line in trimmed.split(separator: "\n") { log(LogLine(text: "$ \(line)", kind: .command)) }
            guard try await effects.run(trimmed, log: log) else {
                markLastLine(kind, recorder, as: .error)
                log(LogLine(text: Note.notPushed.rawValue, kind: .note))
                finish(kind, .failed, recorder, now: now)
                recorder.update {
                    $0.status = .testsFailed
                    $0.finishedAt = now()
                }
                return .finished
            }
            markLastLine(kind, recorder, as: .ok)
            finish(kind, .done, recorder, now: now)
        }

        recorder.update {
            $0[.push].caption = .command
            $0[.push].detail = "git push --force-with-lease"
        }
        start(.push, recorder, attempt: attempt, now: now)
        let pushLog = recorder.log(.push)
        pushLog(LogLine(text: "$ git push --force-with-lease origin \(source)", kind: .command))
        let pushed = try await effects.head()
        switch try await effects.push(source, expected: head, log: pushLog) {
        case .ok:
            markLastLine(.push, recorder, as: .ok)
            finish(.push, .done, recorder, now: now)
            recorder.update { $0.pushedSHA = pushed }
        case .rejected:
            markLastLine(.push, recorder, as: .error)
            finish(.push, .failed, recorder, now: now) { $0.caption = .pushRejected }
            recorder.update { $0.status = .branchChanged }
            guard attempt < config.maxAttempts else {
                recorder.update { $0.finishedAt = now() }
                return .finished
            }
            pushLog(LogLine(text: Note.restart.rawValue, kind: .note))
            try await effects.sleep(config.restartDelay)
            return .restart
        case .failed(let message):
            markLastLine(.push, recorder, as: .error)
            finish(.push, .failed, recorder, now: now)
            recorder.update {
                $0.status = .pushFailed(message: message)
                $0.finishedAt = now()
            }
            return .finished
        }

        release()
        return try await watchCI(sha: pushed, pushed: true, recorder, attempt: attempt, now: now)
    }

    private func watchCI(sha: String, pushed: Bool, _ recorder: RunRecorder, attempt: Int, now: @Sendable () -> Date)
        async throws -> Outcome
    {
        recorder.update { $0[.ci].caption = .pipeline }
        start(.ci, recorder, attempt: attempt, now: now)
        let log = recorder.log(.ci)
        let started = now()
        var announced: Int?
        while true {
            try Task.checkCancellation()
            let waited = now().timeIntervalSince(started)
            if let pipeline = try await effects.pipeline(sha: sha) {
                if announced != pipeline.id {
                    announced = pipeline.id
                    recorder.update { $0.pipelineID = pipeline.id }
                    log(LogLine(text: "pipeline #\(pipeline.id)", kind: .output))
                }
                switch pipeline.status {
                case .running:
                    break
                case .passed:
                    log(LogLine(text: Note.ciPassed.rawValue, kind: .note))
                    finish(.ci, .done, recorder, now: now) { $0.caption = .ciPassed }
                    recorder.update {
                        $0.status = .upToDate(pushed: pushed)
                        $0.finishedAt = now()
                    }
                    return .finished
                case .failed:
                    let job = try await effects.failedJob(pipeline: pipeline.id)
                    let name = job?.name ?? "pipeline"
                    log(LogLine(text: "\(name): failed", kind: .error))
                    finish(.ci, .failed, recorder, now: now) {
                        $0.caption = .ciFailed
                        $0.detail = name
                    }
                    recorder.update {
                        $0.status = .ciFailed(job: name)
                        $0.failedJobID = job?.id
                        $0.finishedAt = now()
                    }
                    return .finished
                }
            } else if waited >= config.ciAppearTimeout {
                finish(.ci, .skipped, recorder, now: now)
                recorder.update {
                    $0.status = .upToDate(pushed: pushed)
                    $0.finishedAt = now()
                }
                return .finished
            }
            if waited >= config.ciTimeout {
                finish(.ci, .skipped, recorder, now: now)
                recorder.update {
                    $0.status = .upToDate(pushed: pushed)
                    $0.finishedAt = now()
                }
                return .finished
            }
            try await effects.sleep(config.ciPollInterval)
        }
    }

    private func start(_ kind: StageKind, _ recorder: RunRecorder, attempt: Int, now: () -> Date) {
        recorder.update { run in
            run[kind].state = .running
            run[kind].startedAt = now()
            run.status = .running(kind, attempt: attempt)
        }
    }

    private func finish(
        _ kind: StageKind, _ state: StageState, _ recorder: RunRecorder, now: () -> Date,
        _ change: (inout Stage) -> Void = { _ in }
    ) {
        recorder.update { run in
            var stage = run[kind]
            stage.state = state
            if let started = stage.startedAt { stage.duration = now().timeIntervalSince(started) }
            change(&stage)
            run[kind] = stage
        }
    }

    private func markLastLine(_ kind: StageKind, _ recorder: RunRecorder, as lineKind: LogLine.Kind) {
        recorder.update { run in
            guard let index = run[kind].log.lastIndex(where: { $0.kind == .output }) else { return }
            var stage = run[kind]
            if lineKind == .ok && index != stage.log.count - 1 { return }
            stage.log[index].kind = lineKind
            run[kind] = stage
        }
    }

    private func fail(_ recorder: RunRecorder, error: Error, now: () -> Date) {
        recorder.update { run in
            guard let kind = run.stages.first(where: { $0.state == .running })?.kind else { return }
            run[kind].state = .failed
            run[kind].log.append(LogLine(text: Self.describe(error), kind: .error))
            if let started = run[kind].startedAt { run[kind].duration = now().timeIntervalSince(started) }
            run.status = .error(message: Self.describe(error))
            run.finishedAt = now()
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let git as GitError:
            git.output.split(separator: "\n").last.map(String.init) ?? git.command
        case let gitlab as GitLabError:
            String(describing: gitlab)
        case let claude as ClaudeError:
            claude.message
        default:
            error.localizedDescription
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}
