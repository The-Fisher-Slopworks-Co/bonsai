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

    private func start(_ kind: StageKind, _ recorder: Recorder<MainCheck>, now: () -> Date) {
        recorder.update { check in
            check[kind].state = .running
            check[kind].startedAt = now()
        }
    }

    private func finish(_ kind: StageKind, _ state: StageState, _ recorder: Recorder<MainCheck>, now: () -> Date) {
        recorder.update { check in
            check[kind].state = state
            if let started = check[kind].startedAt { check[kind].duration = now().timeIntervalSince(started) }
        }
    }

    private func markLastLine(_ kind: StageKind, _ recorder: Recorder<MainCheck>, as lineKind: LogLine.Kind) {
        recorder.update { check in
            guard let index = check[kind].log.lastIndex(where: { $0.kind == .output }),
                lineKind == .error || index == check[kind].log.count - 1
            else { return }
            check[kind].log[index].kind = lineKind
        }
    }
}
