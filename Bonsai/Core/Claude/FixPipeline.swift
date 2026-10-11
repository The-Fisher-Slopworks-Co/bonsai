import Foundation

struct FixPipeline: Sendable {
    struct Config: Sendable {
        var attempts = 2
        var autoPush = false
        var language = "Russian"
        var ciPollInterval: TimeInterval = 10
        var ciAppearTimeout: TimeInterval = 90
        var ciTimeout: TimeInterval = 3 * 3600
        var maxConflictStops = 10
    }

    var mr: MergeRequest
    var project: Project
    var effects: any FixEffects
    var rules: String
    var config = Config()

    func fix(_ kind: ClaudeFix.Kind, _ recorder: RunRecorder, now: @Sendable () -> Date = Date.init) async -> MRRun {
        let failed = recorder.run
        recorder.update { run in
            var fix = ClaudeFix(
                kind: kind, phase: .fixing, maxAttempts: config.attempts,
                stages: ClaudeFix.stageKinds(for: kind).map { Stage(kind: $0) },
                worktree: effects.worktree.path, baseSHA: mr.sha, startedAt: now())
            if case .ciFailed(let job) = failed.status { fix.job = job }
            fix[.retest].caption = .afterFix
            fix[.retest].detail = firstLine(project.test)
            fix[.push].caption = .command
            fix[.push].detail = "git push --force-with-lease"
            fix[.ci].caption = .pipeline
            if kind == .conflict {
                fix[.continueRebase].caption = .command
                fix[.continueRebase].detail = "git rebase --continue"
                fix[.setup].caption = project.setup.isEmpty ? .none : .command
                fix[.setup].detail = firstLine(project.setup)
            }
            run.fix = fix
        }
        do {
            return try await attempt(kind, failed: failed, recorder, now: now)
        } catch is CancellationError {
            await effects.discard()
            recorder.update { run in
                run.fix?.phase = .stopped
                run.fix?.files = []
            }
            return recorder.run
        } catch {
            return await giveUp(recorder, error: error, now: now)
        }
    }

    private func attempt(_ kind: ClaudeFix.Kind, failed: MRRun, _ recorder: RunRecorder, now: @Sendable () -> Date)
        async throws -> MRRun
    {
        let claudeLog = recorder.fixLog(.claude)
        start(.claude, recorder, now: now)
        recorder.update {
            $0.fix?[.claude].caption = .claudeAttempt
            $0.fix?[.claude].detail = "1/\(config.attempts)"
        }

        try await effects.prepare(branch: mr.sourceBranch, log: { _ in })
        var conflictFiles: [String] = []
        var conflicted: [String: String] = [:]
        switch kind {
        case .tests:
            if case .conflict = try await effects.rebase(onto: "origin/\(project.targetBranch)", log: { _ in }) {
                throw ClaudeError(message: "rebase conflict")
            }
        case .ci:
            break
        case .conflict:
            claudeLog(LogLine(text: "$ git rebase origin/\(project.targetBranch)", kind: .command))
            switch try await effects.rebase(onto: "origin/\(project.targetBranch)", log: claudeLog) {
            case .ok:
                throw ClaudeError(message: "no conflict")
            case .conflict(let files):
                conflictFiles = files
                for file in files { conflicted[file] = effects.read(file) }
            }
        }

        var prompt = FixPrompt(
            kind: kind, branch: mr.sourceBranch, base: "origin/\(project.targetBranch)", setup: project.setup,
            test: project.test, rules: rules, projectRules: project.rules, conflictFiles: conflictFiles,
            language: config.language)
        switch kind {
        case .tests:
            prompt.failureLog = (failed[.setup].state == .failed ? failed[.setup] : failed[.test]).log.map(\.text)
                .joined(separator: "\n")
        case .ci:
            prompt.job = recorder.run.fix?.job
            if let job = failed.failedJobID { prompt.failureLog = (try? await effects.jobLog(job)) ?? "" }
        case .conflict:
            break
        }

        var session: String?
        var lastFailure = ""
        var allConflicted = conflicted
        var attempt = 1
        while true {
            recorder.update { run in
                run.fix?.attempt = attempt
                run.fix?[.claude].detail = "\(attempt)/\(config.attempts)"
                run.fix?[.claude].state = .running
                run.fix?.phase = .fixing
                for kind in [StageKind.continueRebase, .setup, .retest] where run.fix?[kind].state != .pending {
                    run.fix?[kind].state = .pending
                    run.fix?[kind].log = []
                    run.fix?[kind].duration = nil
                }
            }
            let text = session == nil ? prompt.text : prompt.retry(testOutput: lastFailure)
            let result = try await runClaude(text, tools: prompt.allowedTools, resume: session, recorder)
            session = result.sessionID ?? session
            if result.isError { throw ClaudeError(message: result.errorText ?? "claude") }

            if kind == .conflict && attempt == 1 {
                start(.continueRebase, recorder, now: now)
                let continueLog = recorder.fixLog(.continueRebase)
                continueLog(LogLine(text: "$ git add -A", kind: .command))
                continueLog(LogLine(text: "$ git rebase --continue", kind: .command))
                var stops = 0
                while case .conflict(let files) = try await effects.continueRebase(log: continueLog) {
                    stops += 1
                    guard stops < config.maxConflictStops else { throw ClaudeError(message: "too many conflicts") }
                    for file in files { allConflicted[file] = effects.read(file) }
                    var next = prompt
                    next.conflictFiles = files
                    let more = try await runClaude(next.text, tools: next.allowedTools, resume: session, recorder)
                    session = more.sessionID ?? session
                    if more.isError { throw ClaudeError(message: more.errorText ?? "claude") }
                }
                finish(.continueRebase, .done, recorder, now: now)
                if !project.setup.trimmingCharacters(in: .whitespaces).isEmpty {
                    start(.setup, recorder, now: now)
                    let setupLog = recorder.fixLog(.setup)
                    setupLog(LogLine(text: "$ \(firstLine(project.setup))", kind: .command))
                    let setup = try await effects.run(project.setup, log: setupLog)
                    finish(.setup, setup.ok ? .done : .failed, recorder, now: now)
                } else {
                    recorder.update { $0.fix?[.setup].state = .skipped }
                }
            }

            recorder.update { $0.fix?.phase = .checking }
            if try await retest(recorder, now: now, withSetup: kind != .conflict && attempt == 1) {
                break
            }
            lastFailure = recorder.run.fix?[.retest].log.map(\.text).joined(separator: "\n") ?? ""
            guard attempt < config.attempts else {
                return await giveUp(recorder, error: nil, now: now)
            }
            attempt += 1
        }

        let files = try await describe(kind, conflicted: allConflicted, recorder)
        recorder.update { run in
            guard run.fix != nil else { return }
            run.fix!.files = files
            run.fix!.testsTouched = kind != .conflict && files.contains { DiffParser.isTestPath($0.path) }
            run.fix!.ownCode = files.contains { $0.kind == .conflict && ($0.hasOwnCode || $0.conflicts.isEmpty) }
            var claude = run.fix![.claude]
            claude.state = .done
            if let started = claude.startedAt { claude.duration = now().timeIntervalSince(started) }
            if kind == .conflict {
                claude.caption = .claudeResolved
                claude.detail = String(run.fix!.resolvedConflicts)
            } else {
                claude.caption = .claudeChanged
                claude.detail =
                    "\(files.count)/\(files.reduce(0) { $0 + $1.added })/\(files.reduce(0) { $0 + $1.removed })"
            }
            run.fix![.claude] = claude
            run.fix!.phase = .ready
        }
        let fix = recorder.run.fix
        if config.autoPush, let fix, !(fix.kind == .conflict && fix.ownCode) {
            return await push(message: fix.commitMessage, recorder, now: now)
        }
        return recorder.run
    }

    private func runClaude(_ prompt: String, tools: [String], resume: String?, _ recorder: RunRecorder) async throws
        -> ClaudeResult
    {
        let log = recorder.fixLog(.claude)
        let result = try await effects.claude(prompt: prompt, tools: tools, resume: resume) { event in
            switch event {
            case .started(let id):
                recorder.update { $0.fix?.sessionID = id }
            case .log(let line):
                log(line)
            case .finished:
                break
            }
        }
        recorder.update { run in
            if let id = result.sessionID { run.fix?.sessionID = id }
            if !result.summary.isEmpty { run.fix?.summary = result.summary }
            if !result.commitMessage.isEmpty { run.fix?.commitMessage = result.commitMessage }
            pendingNotes(run: &run, result.notes)
        }
        return result
    }

    private func pendingNotes(run: inout MRRun, _ notes: [String: String]) {
        guard !notes.isEmpty else { return }
        for index in run.fix?.files.indices ?? 0..<0 where notes[run.fix!.files[index].path] != nil {
            run.fix!.files[index].note = notes[run.fix!.files[index].path]
        }
        noteStore.merge(notes)
    }

    private let noteStore = Notes()

    private func retest(_ recorder: RunRecorder, now: @Sendable () -> Date, withSetup: Bool) async throws -> Bool {
        start(.retest, recorder, now: now)
        let log = recorder.fixLog(.retest)
        if withSetup && !project.setup.trimmingCharacters(in: .whitespaces).isEmpty {
            for line in project.setup.split(separator: "\n") { log(LogLine(text: "$ \(line)", kind: .command)) }
            guard try await effects.run(project.setup, log: log).ok else {
                finish(.retest, .failed, recorder, now: now)
                return false
            }
        }
        for line in project.test.split(separator: "\n") { log(LogLine(text: "$ \(line)", kind: .command)) }
        let ok = try await effects.run(project.test, log: log).ok
        if ok { markLastOutput(recorder) }
        finish(.retest, ok ? .done : .failed, recorder, now: now)
        return ok
    }

    private func describe(_ kind: ClaudeFix.Kind, conflicted: [String: String], _ recorder: RunRecorder) async throws
        -> [FixFile]
    {
        var files: [FixFile]
        if kind == .conflict {
            files = conflicted.keys.sorted().map { path in
                let before = conflicted[path] ?? ""
                let after = effects.read(path) ?? ""
                let count =
                    ConflictAnalysis.segments(before)?.filter { if case .conflict = $0 { true } else { false } }.count
                    ?? 1
                if FixPrompt.isLockFile(path) {
                    let placeholder = ResolvedConflict(startLine: 1, endLine: 1, source: .both, lines: [], dropped: [])
                    return FixFile(
                        path: path, kind: .lock, conflicts: Array(repeating: placeholder, count: max(1, count)))
                }
                let resolved = ConflictAnalysis.analyze(conflicted: before, resolved: after) ?? []
                return FixFile(path: path, kind: .conflict, conflicts: resolved)
            }
            files += DiffParser.parse(try await effects.diff())
        } else {
            files = DiffParser.parse(try await effects.diff())
        }
        let notes = noteStore.all
        for index in files.indices { files[index].note = notes[files[index].path] }
        return files
    }

    private func giveUp(_ recorder: RunRecorder, error: Error?, now: @Sendable () -> Date) async -> MRRun {
        if let error {
            recorder.fixLog(.claude)(LogLine(text: MRPipeline.describe(error), kind: .error))
        }
        recorder.update { run in
            guard run.fix != nil else { return }
            var claude = run.fix![.claude]
            claude.state = .failed
            claude.caption = .claudeFailed
            claude.detail = String(run.fix!.attempt)
            if let started = claude.startedAt { claude.duration = now().timeIntervalSince(started) }
            run.fix![.claude] = claude
            for kind in [StageKind.continueRebase, .setup, .retest, .push, .ci] where run.fix![kind].state == .running {
                run.fix![kind].state = .pending
            }
            run.fix!.phase = .gaveUp
            run.fix!.files = []
        }
        return recorder.run
    }

    func push(message: String, _ recorder: RunRecorder, now: @Sendable () -> Date = Date.init) async -> MRRun {
        guard let fix = recorder.run.fix else { return recorder.run }
        recorder.update {
            $0.fix?.phase = .pushing
            $0.fix?.commitMessage = message
        }
        start(.push, recorder, now: now)
        let log = recorder.fixLog(.push)
        do {
            if fix.kind == .conflict {
                if try await effects.isDirty { try await effects.commit("", amend: true) }
            } else {
                try await effects.commit(message, amend: false)
            }
            let sha = try await effects.head()
            log(LogLine(text: "$ git push --force-with-lease origin \(mr.sourceBranch)", kind: .command))
            switch try await effects.push(mr.sourceBranch, sha: sha, expected: fix.baseSHA, log: log) {
            case .ok:
                markLastOutput(recorder, kind: .push)
                finish(.push, .done, recorder, now: now)
                recorder.update { run in
                    run.fix?.pushedSHA = sha
                    run.fix?.phase = .ci
                    run.pushedSHA = sha
                    run.headSHA = sha
                }
            case .rejected:
                finish(.push, .failed, recorder, now: now)
                recorder.update { $0.fix?[.push].caption = .pushRejected }
                await effects.discard()
                recorder.update { $0.fix?.phase = .stopped }
                return recorder.run
            case .failed(let message):
                log(LogLine(text: message, kind: .error))
                finish(.push, .failed, recorder, now: now)
                await effects.discard()
                recorder.update { $0.fix?.phase = .stopped }
                return recorder.run
            }
            await effects.discard()
            return try await watchCI(sha: sha, recorder, now: now)
        } catch is CancellationError {
            return recorder.run
        } catch {
            log(LogLine(text: MRPipeline.describe(error), kind: .error))
            finish(.push, .failed, recorder, now: now)
            recorder.update { $0.fix?.phase = .ready }
            return recorder.run
        }
    }

    private func watchCI(sha: String, _ recorder: RunRecorder, now: @Sendable () -> Date) async throws -> MRRun {
        start(.ci, recorder, now: now)
        let log = recorder.fixLog(.ci)
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
                    finish(.ci, .done, recorder, now: now)
                    recorder.update { run in
                        run.fix?[.ci].caption = .ciPassed
                        run.fix?.phase = .pushed
                        run.status = .upToDate(pushed: true)
                        run.finishedAt = now()
                    }
                    return recorder.run
                case .failed:
                    let job = try await effects.failedJob(pipeline: pipeline.id)
                    let name = job?.name ?? "pipeline"
                    log(LogLine(text: "\(name): failed", kind: .error))
                    finish(.ci, .failed, recorder, now: now)
                    recorder.update { run in
                        run.fix?[.ci].caption = .ciFailed
                        run.fix?[.ci].detail = name
                        run.fix?.phase = .pushed
                        run.status = .ciFailed(job: name)
                        run.failedJobID = job?.id
                        run.finishedAt = now()
                    }
                    return recorder.run
                }
            } else if waited >= config.ciAppearTimeout || waited >= config.ciTimeout {
                finish(.ci, .skipped, recorder, now: now)
                recorder.update { run in
                    run.fix?.phase = .pushed
                    run.status = .upToDate(pushed: true)
                    run.finishedAt = now()
                }
                return recorder.run
            }
            try await effects.sleep(config.ciPollInterval)
        }
    }

    func revert(_ recorder: RunRecorder, failure: MRStatus, now: @Sendable () -> Date = Date.init) async -> MRRun {
        guard let fix = recorder.run.fix, let pushed = fix.pushedSHA else { return recorder.run }
        let log = recorder.fixLog(.push)
        do {
            switch try await effects.push(mr.sourceBranch, sha: fix.baseSHA, expected: pushed, log: log) {
            case .ok:
                recorder.update { run in
                    run.fix?.phase = .reverted
                    run.status = failure
                    run.headSHA = fix.baseSHA
                    run.pushedSHA = nil
                }
            case .rejected, .failed:
                break
            }
        } catch {
            log(LogLine(text: MRPipeline.describe(error), kind: .error))
        }
        return recorder.run
    }

    func recheck(_ recorder: RunRecorder, now: @Sendable () -> Date = Date.init) async -> MRRun {
        guard let fix = recorder.run.fix else { return recorder.run }
        recorder.update { $0.fix?.phase = .checking }
        do {
            guard try await retest(recorder, now: now, withSetup: false) else {
                recorder.update { $0.fix?.phase = .terminal }
                return recorder.run
            }
            let files = try await describe(fix.kind == .conflict ? .tests : fix.kind, conflicted: [:], recorder)
            recorder.update { run in
                if fix.kind != .conflict || !files.isEmpty {
                    run.fix?.files = fix.kind == .conflict ? fix.files + files : files
                }
                run.fix?.testsTouched = fix.kind != .conflict && files.contains { DiffParser.isTestPath($0.path) }
                run.fix?.phase = .ready
            }
            if config.autoPush && !(fix.kind == .conflict && fix.ownCode) {
                return await push(message: recorder.run.fix?.commitMessage ?? "", recorder, now: now)
            }
        } catch is CancellationError {
        } catch {
            recorder.update { $0.fix?.phase = .terminal }
        }
        return recorder.run
    }

    private func start(_ kind: StageKind, _ recorder: RunRecorder, now: () -> Date) {
        recorder.update { run in
            run.fix?[kind].state = .running
            run.fix?[kind].startedAt = now()
        }
    }

    private func finish(_ kind: StageKind, _ state: StageState, _ recorder: RunRecorder, now: () -> Date) {
        recorder.update { run in
            guard var stage = run.fix?[kind] else { return }
            stage.state = state
            if let started = stage.startedAt { stage.duration = now().timeIntervalSince(started) }
            run.fix?[kind] = stage
        }
    }

    private func markLastOutput(_ recorder: RunRecorder, kind: StageKind = .retest) {
        recorder.update { run in
            guard let index = run.fix?[kind].log.lastIndex(where: { $0.kind == .output }),
                index == (run.fix?[kind].log.count ?? 0) - 1
            else { return }
            run.fix?[kind].log[index].kind = .ok
        }
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String: String] = [:]
    func merge(_ more: [String: String]) { lock.withLock { notes.merge(more) { _, new in new } } }
    var all: [String: String] { lock.withLock { notes } }
}
