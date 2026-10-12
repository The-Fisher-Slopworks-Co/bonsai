// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct MainPipeline: Sendable {
    var project: Project
    var effects: any PipelineEffects

    private var target: String { project.targetBranch }

    func check(_ recorder: Recorder<MainCheck>, now: @Sendable () -> Date = Date.init) async throws -> MainCheck {
        let sha = recorder.run.sha
        let commands = recorder.run.commands
        let ci = try? await effects.pipeline(sha: sha)
        recorder.update { check in
            check.phase = .checking
            check.stages = [Stage(kind: .checkout, caption: .ref, detail: "origin/\(target) · \(sha.prefix(7))")]
            for (kind, command) in [(StageKind.setup, commands.setup), (.test, commands.test)] {
                check.stages.append(
                    command.isEmpty
                        ? Stage(kind: kind, state: .skipped)
                        : Stage(kind: kind, caption: .command, detail: Self.oneLine(command)))
            }
            if let ci, ci.status != .running {
                check.stages.insert(
                    Stage(
                        kind: .ci, state: ci.status == .passed ? .done : .failed,
                        caption: ci.status == .passed ? .mainCiPassed : .mainCiFailed), at: 0)
            }
        }
        if let ci, ci.status != .running {
            let log = recorder.log(.ci)
            log(LogLine(text: "pipeline #\(ci.id) · \(target) · \(sha.prefix(7))", kind: .output))
            if ci.status == .failed, let job = try? await effects.failedJob(pipeline: ci.id) {
                log(LogLine(text: "\(job.name): failed", kind: .error))
            }
        }

        start(.checkout, recorder, now: now)
        let checkoutLog = recorder.log(.checkout)
        checkoutLog(LogLine(text: "$ git checkout --detach origin/\(target)", kind: .command))
        try await effects.detach("origin/\(target)", log: checkoutLog)
        finish(.checkout, .done, recorder, now: now)

        for (kind, command) in [(StageKind.setup, commands.setup), (.test, commands.test)] where !command.isEmpty {
            start(kind, recorder, now: now)
            let log = recorder.log(kind)
            for line in command.split(separator: "\n") { log(LogLine(text: "$ \(line)", kind: .command)) }
            guard try await effects.run(command, log: log) else {
                markLastLine(kind, recorder, as: .error)
                finish(kind, .failed, recorder, now: now)
                recorder.update { check in
                    check.phase = Self.verdict(ci: ci?.status, commands: commands, lastPassed: check.lastPassed)
                    check.finishedAt = now()
                }
                return recorder.run
            }
            markLastLine(kind, recorder, as: .ok)
            finish(kind, .done, recorder, now: now)
        }
        recorder.update { check in
            check.phase = .passed
            check.lastPassed = commands
            check.finishedAt = now()
        }
        return recorder.run
    }

    typealias Claude =
        @Sendable (_ prompt: String, _ resume: String?, _ onEvent: @escaping @Sendable (ClaudeEvent) -> Void)
        async throws -> ClaudeResult

    func fix(
        _ prompt: CommandPrompt, attempts: Int, claude: Claude, _ recorder: Recorder<MainCheck>,
        now: @Sendable () -> Date = Date.init
    ) async -> MainCheck {
        let kind: StageKind = prompt.pick ? .pick : .claude
        let fallback: MainCheck.Phase = prompt.pick ? .missing : .failed
        recorder.update { check in
            check.phase = .fixing
            check.proposal = MainCheck.Proposal(
                stages: [Stage(kind: kind, caption: .commandsOnly), Stage(kind: .setup), Stage(kind: .test)])
        }
        start(kind, recorder, now: now, fix: true)
        let log = recorder.fixLog(kind)
        do {
            try await effects.detach("origin/\(target)", log: { _ in })
            var session: String?
            var lastFailure = ""
            for attempt in 1...max(1, attempts) {
                recorder.update { check in
                    for stage in [StageKind.setup, .test] { check.proposal?[stage] = Stage(kind: stage) }
                }
                let text = attempt == 1 ? prompt.text : prompt.retry(output: lastFailure)
                let result = try await claude(text, session) { event in
                    switch event {
                    case .started(let id): recorder.update { $0.proposal?.sessionID = id }
                    case .log(let line): log(line)
                    case .finished: break
                    }
                }
                session = result.sessionID ?? session
                if result.isError { throw ClaudeError(message: result.errorText ?? "claude") }
                let commands = MainCheck.Commands(setup: result.setup ?? "", test: result.test ?? "")
                recorder.update { check in
                    check.proposal?.commands = commands
                    check.proposal?.summary = result.summary
                }
                if try await verify(commands, pick: prompt.pick, recorder, now: now) {
                    let detail = Self.changes(from: recorder.run.commands, to: commands)
                    finish(kind, .done, recorder, now: now, fix: true)
                    recorder.update { check in
                        check.proposal?[kind].caption = .commandsChanged
                        check.proposal?[kind].detail = detail
                        check.phase = .ready
                        check.finishedAt = now()
                    }
                    return recorder.run
                }
                let failed = recorder.run.proposal?.stages.first { $0.state == .failed }
                lastFailure = failed?.log.map(\.text).joined(separator: "\n") ?? ""
            }
            giveUp(kind, attempts: attempts, phase: fallback, recorder, now: now)
        } catch is CancellationError {
            recorder.update { check in
                check.phase = .stopped
                check.proposal = nil
            }
        } catch {
            log(LogLine(text: MRPipeline.describe(error), kind: .error))
            giveUp(kind, attempts: attempts, phase: fallback, recorder, now: now)
        }
        return recorder.run
    }

    private func verify(
        _ commands: MainCheck.Commands, pick: Bool, _ recorder: Recorder<MainCheck>, now: @Sendable () -> Date
    ) async throws -> Bool {
        try await effects.detach("origin/\(target)", log: { _ in })
        guard !commands.test.isEmpty else {
            recorder.update { $0.proposal?[.test].state = .failed }
            return false
        }
        for (kind, command) in [(StageKind.setup, commands.setup), (.test, commands.test)] {
            guard !command.isEmpty else {
                recorder.update { $0.proposal?[kind].state = .skipped }
                continue
            }
            recorder.update { check in
                check.proposal?[kind].caption = kind == .test && !pick ? .afterFix : .command
                check.proposal?[kind].detail = Self.oneLine(command)
            }
            start(kind, recorder, now: now, fix: true)
            let log = recorder.fixLog(kind)
            for line in command.split(separator: "\n") { log(LogLine(text: "$ \(line)", kind: .command)) }
            let ok = try await effects.run(command, log: log)
            markLastLine(kind, recorder, as: ok ? .ok : .error, fix: true)
            finish(kind, ok ? .done : .failed, recorder, now: now, fix: true)
            if !ok { return false }
        }
        return true
    }

    private func giveUp(
        _ kind: StageKind, attempts: Int, phase: MainCheck.Phase, _ recorder: Recorder<MainCheck>, now: () -> Date
    ) {
        finish(kind, .failed, recorder, now: now, fix: true)
        recorder.update { check in
            check.proposal?[kind].caption = .claudeFailed
            check.proposal?[kind].detail = String(attempts)
            for stage in [StageKind.setup, .test] where check.proposal?[stage].state == .running {
                check.proposal?[stage].state = .pending
            }
            check.phase = phase
            check.finishedAt = now()
        }
    }

    static func changes(from old: MainCheck.Commands, to new: MainCheck.Commands) -> String {
        let before = Set((old.setup + "\n" + old.test).split(separator: "\n"))
        let added = (new.setup + "\n" + new.test).split(separator: "\n").filter { !before.contains($0) }.count
        return "\(new.setup != old.setup ? 1 : 0)/\(new.test != old.test ? 1 : 0)/\(added)"
    }

    static func verdict(ci: CIPipeline.Status?, commands: MainCheck.Commands, lastPassed: MainCheck.Commands?)
        -> MainCheck.Phase
    {
        switch ci {
        case .passed: .failed
        case .failed: .broken
        case .running, nil: lastPassed == commands ? .broken : .failed
        }
    }

    static func oneLine(_ command: String) -> String {
        command.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " && ")
    }

    private func start(_ kind: StageKind, _ recorder: Recorder<MainCheck>, now: () -> Date, fix: Bool = false) {
        recorder.update { check in
            Self.edit(&check, kind, fix: fix) { stage in
                stage.state = .running
                stage.startedAt = now()
            }
        }
    }

    private func finish(
        _ kind: StageKind, _ state: StageState, _ recorder: Recorder<MainCheck>, now: () -> Date, fix: Bool = false
    ) {
        recorder.update { check in
            Self.edit(&check, kind, fix: fix) { stage in
                stage.state = state
                if let started = stage.startedAt { stage.duration = now().timeIntervalSince(started) }
            }
        }
    }

    private func markLastLine(
        _ kind: StageKind, _ recorder: Recorder<MainCheck>, as lineKind: LogLine.Kind, fix: Bool = false
    ) {
        recorder.update { check in
            Self.edit(&check, kind, fix: fix) { stage in
                guard let index = stage.log.lastIndex(where: { $0.kind == .output }),
                    lineKind == .error || index == stage.log.count - 1
                else { return }
                stage.log[index].kind = lineKind
            }
        }
    }

    private static func edit(_ check: inout MainCheck, _ kind: StageKind, fix: Bool, _ body: (inout Stage) -> Void) {
        if fix {
            guard var stage = check.proposal?[kind] else { return }
            body(&stage)
            check.proposal?[kind] = stage
        } else {
            var stage = check[kind]
            body(&stage)
            check[kind] = stage
        }
    }
}
