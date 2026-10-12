// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Observation

@MainActor
@Observable
final class Workspace {
    enum Loading: Equatable {
        case loading, loaded
    }

    struct ProjectState: Equatable {
        var loading: Loading = .loading
        var mergeRequests: [MergeRequest] = []
        var checkedAt: Date?
        var error: String?
    }

    struct StatusChange {
        var mr: MergeRequest
        var project: Project
        var old: MRStatus
        var new: MRStatus
        var oldFix: ClaudeFix.Phase? = nil
        var newFix: ClaudeFix.Phase? = nil
    }

    let store: Store
    private let configuration: @Sendable () -> URLSessionConfiguration
    var makeEffects: ((Project, GitRunner, GitLabClient) -> any PipelineEffects)?
    var pipelineConfig = MRPipeline.Config()
    var onStatusChange: ((StatusChange) -> Void)?

    private(set) var states: [Int: ProjectState] = [:]
    private(set) var runs: [String: MRRun]
    private(set) var mainChecks: [Int: MainCheck]
    private(set) var connectionLost = false
    var claude: ClaudeCLI.Check?
    var makeClaudeRunner: () -> any ClaudeRunning = { LiveClaudeRunner() }
    var fixConfig = FixPipeline.Config()
    var openTerminal: ((URL) -> Void)?

    private var workers: [Int: Task<Void, Never>] = [:]
    private var again: Set<Int> = []
    private var forced: [Int: [String]] = [:]
    private var recheckMain: Set<Int> = []
    private var mainTasks: [Int: Task<Void, Never>] = [:]
    private var mainGenerations: [Int: Int] = [:]
    private var mainRevisions: [Int: Int] = [:]
    private var mrTasks: [String: Task<Void, Never>] = [:]
    private var stopped: Set<String> = []
    private var behindCounts: [String: Int] = [:]
    private var generations: [String: Int] = [:]
    private var revisions: [String: Int] = [:]
    private let slots = Slots()

    init(store: Store, configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.store = store
        self.configuration = configuration
        runs = store.loadRuns()
        mainChecks = store.loadMainChecks()
        for (id, check) in mainChecks where check.phase == .fixing {
            mainChecks[id]?.phase = .stopped
            mainChecks[id]?.proposal = nil
        }
        for (id, run) in runs where !run.status.isFinal {
            runs[id]?.status = .unknown
        }
        let saved = store.loadMergeRequests()
        for project in store.projects {
            if let mrs = saved[project.id] {
                states[project.id] = ProjectState(loading: .loaded, mergeRequests: mrs)
            }
        }
    }

    func state(_ project: Project) -> ProjectState {
        states[project.id] ?? ProjectState()
    }

    func run(_ mr: MergeRequest) -> MRRun {
        runs[mr.id] ?? MRRun()
    }

    func mainCheck(_ project: Project) -> MainCheck? {
        mainChecks[project.id]
    }

    func isWaiting(_ project: Project) -> Bool {
        mainChecks[project.id]?.phase != .passed
    }

    func project(for mr: MergeRequest) -> Project? {
        store.projects.first { $0.id == mr.projectID }
    }

    var isChecking: Bool { !workers.isEmpty }

    var allMergeRequests: [(MergeRequest, Project)] {
        store.projects.flatMap { project in state(project).mergeRequests.map { ($0, project) } }
    }

    var lastCheck: Date? {
        store.projects.compactMap { states[$0.id]?.checkedAt }.max()
    }

    func client() -> GitLabClient? {
        guard let account = store.account, let token = store.token else { return nil }
        return GitLabClient(
            server: account.server, token: token, trustedFingerprint: account.trustedFingerprint,
            configuration: configuration())
    }

    func git(for project: Project) -> GitRunner {
        GitRunner(
            directory: store.cloneDirectory(for: project), auth: store.gitAuth, identity: store.settings.gitIdentity)
    }

    func add(_ project: Project) {
        guard !store.projects.contains(where: { $0.id == project.id }) else { return }
        store.projects.append(project)
        states[project.id] = ProjectState()
        check(project)
    }

    func update(_ project: Project) {
        guard let index = store.projects.firstIndex(where: { $0.id == project.id }) else { return }
        store.projects[index] = project
    }

    func remove(_ project: Project) async {
        workers[project.id]?.cancel()
        mainTasks[project.id]?.cancel()
        for mr in state(project).mergeRequests { mrTasks[mr.id]?.cancel() }
        await workers[project.id]?.value
        store.projects.removeAll { $0.id == project.id }
        for mr in state(project).mergeRequests { runs[mr.id] = nil }
        states[project.id] = nil
        mainChecks[project.id] = nil
        store.saveRuns(runs)
        store.saveMainChecks(mainChecks)
        store.saveMergeRequests(states.compactMapValues { $0.loading == .loaded ? $0.mergeRequests : nil })
        try? FileManager.default.removeItem(at: store.cloneDirectory(for: project))
    }

    func cancelAll() {
        for worker in workers.values { worker.cancel() }
        for task in mrTasks.values { task.cancel() }
        for task in mainTasks.values { task.cancel() }
    }

    func checkAll(recheck: Bool = false) {
        for project in store.projects where !project.paused { check(project, recheck: recheck) }
    }

    func check(_ project: Project, force: [String] = [], recheck: Bool = false) {
        if !force.isEmpty { forced[project.id, default: []].append(contentsOf: force) }
        if recheck { recheckMain.insert(project.id) }
        if workers[project.id] != nil {
            again.insert(project.id)
            return
        }
        workers[project.id] = Task {
            repeat {
                again.remove(project.id)
                await slots.acquire(limit: max(1, store.settings.parallel))
                if !Task.isCancelled, let current = store.projects.first(where: { $0.id == project.id }) {
                    await pass(current)
                }
                slots.release()
            } while again.contains(project.id) && !Task.isCancelled
            workers[project.id] = nil
        }
    }

    func waitUntilIdle() async {
        while true {
            if let worker = workers.values.first {
                await worker.value
            } else if let task = mrTasks.values.first {
                await task.value
            } else if let task = mainTasks.values.first {
                await task.value
            } else {
                return
            }
        }
    }

    func start(_ mr: MergeRequest) {
        guard let project = project(for: mr), mrTasks[mr.id] == nil else { return }
        check(project, force: [mr.id])
    }

    func stop(_ mr: MergeRequest) {
        guard let task = mrTasks[mr.id] else { return }
        stopped.insert(mr.id)
        task.cancel()
    }

    func rerunCI(_ mr: MergeRequest) {
        guard let project = project(for: mr), let client = client(), mrTasks[mr.id] == nil else { return }
        var current = run(mr)
        guard let pipelineID = current.pipelineID else { return }
        let sha = current.pushedSHA ?? mr.sha
        current[.ci] = Stage(kind: .ci, state: .running, caption: .pipeline, startedAt: Date())
        current.status = .running(.ci, attempt: current.attempt)
        set(current, mr: mr, project: project)
        let pipeline = makePipeline(mr, project, client: client)
        let recorder = recorder(for: mr, project: project, start: current)
        let pushed = current.pushedSHA != nil
        mrTasks[mr.id] = Task {
            do {
                try await client.retryPipeline(project: project.id, pipeline: pipelineID)
            } catch {
                recorder.update {
                    $0.status = .error(message: MRPipeline.describe(error))
                    $0[.ci].state = .failed
                }
                finish(mr, project, recorder)
                return
            }
            _ = await pipeline.watchCIOnly(recorder, sha: sha, pushed: pushed)
            finish(mr, project, recorder)
        }
    }

    private func pass(_ project: Project) async {
        guard let client = client() else { return }
        let git = git(for: project)
        var state = states[project.id] ?? ProjectState()
        let mrs: [MergeRequest]
        let base: String
        do {
            if !git.isRepository {
                try await git.clone(project.cloneURL)
            } else {
                try await git.fetch()
            }
            mrs = filter(try await client.mergeRequests(project: project.id, scope: store.settings.scope), for: project)
            base = try await git.revParse("origin/\(project.targetBranch)")
            connectionLost = false
        } catch {
            if let gitlab = error as? GitLabError, gitlab == .unreachable { connectionLost = true }
            state.error = MRPipeline.describe(error)
            states[project.id] = state
            return
        }

        let open = Set(mrs.map(\.id))
        for id in state.mergeRequests.map(\.id) where !open.contains(id) {
            runs[id] = nil
            mrTasks[id]?.cancel()
        }
        state.mergeRequests = mrs
        state.checkedAt = Date()
        state.loading = .loaded
        state.error = nil
        states[project.id] = state
        store.saveMergeRequests(states.compactMapValues { $0.loading == .loaded ? $0.mergeRequests : nil })

        let recheck = recheckMain.remove(project.id) != nil
        guard let checked = await mainPasses(project, base: base, client: client, recheck: recheck) else { return }

        let force = forced.removeValue(forKey: project.id) ?? []
        var queue: [MergeRequest] = []
        for mr in mrs where mrTasks[mr.id] == nil && !(runs[mr.id]?.fix?.isActive ?? false) {
            let behind =
                (try? await git.behind("origin/\(mr.sourceBranch)", base: "origin/\(project.targetBranch)")) ?? 0
            behindCounts[mr.id] = behind
            guard force.contains(mr.id) || needsRun(runs[mr.id], mr: mr, base: base) else { continue }
            if runs[mr.id]?.fix != nil { await discardWorktree(mr, project) }
            if behind > 0 {
                var queued = MRRun()
                queued.status = .behind(commits: behind)
                set(queued, mr: mr, project: project)
            }
            queue.append(mr)
        }
        queue.sort { force.contains($0.id) && !force.contains($1.id) }
        store.saveRuns(runs)

        for mr in queue {
            let paused = store.projects.first { $0.id == project.id }?.paused ?? true
            guard !Task.isCancelled, !paused || force.contains(mr.id) else { continue }
            await runPipeline(mr, checked, client: client)
        }
    }

    private func mainPasses(_ project: Project, base: String, client: GitLabClient, recheck: Bool) async
        -> Project?
    {
        var project = project
        var commands = MainCheck.Commands(project)
        let previous = mainChecks[project.id]
        if let previous, previous.sha == base, previous.commands == commands {
            if previous.phase == .passed { return project }
            if previous.phase != .checking && !recheck { return nil }
        }
        if mainTasks[project.id] != nil || (previous?.phase == .ready && previous?.commands == commands) { return nil }
        let git = git(for: project)
        if commands.test.isEmpty {
            let start = MainCheck(sha: base, commands: commands, lastPassed: previous?.lastPassed, pick: true)
            if canFixMain(project) {
                startMainFix(project, check: start)
                return nil
            }
            guard let found = await detectCommands(project, git: git) else {
                var missing = start
                missing.phase = .missing
                setMain(missing, project: project)
                return nil
            }
            project.setup = found.setup
            project.test = found.test
            update(project)
            commands = MainCheck.Commands(project)
        }
        let start = MainCheck(sha: base, commands: commands, lastPassed: previous?.lastPassed)
        let recorder = mainRecorder(project, start: start)
        do {
            let result = try await MainPipeline(project: project, effects: mainEffects(project, client: client))
                .check(recorder)
            setMain(result, project: project)
            return result.phase == .passed ? project : nil
        } catch {
            setMain(previous, project: project)
            if !(error is CancellationError) { states[project.id]?.error = MRPipeline.describe(error) }
            return nil
        }
    }

    private func mainEffects(_ project: Project, client: GitLabClient) -> any PipelineEffects {
        let git = git(for: project)
        return makeEffects?(project, git, client)
            ?? LivePipelineEffects(git: git, gitlab: client, projectID: project.id)
    }

    private func detectCommands(_ project: Project, git: GitRunner) async -> DetectedCommands? {
        let ref = "origin/\(project.targetBranch)"
        guard let listing = try? await git.checked(["ls-tree", "--name-only", ref]) else { return nil }
        let files = listing.split(separator: "\n").map(String.init)
        return try? await CommandDetector.detect(files: files) { path in
            try? await git.checked(["show", "\(ref):\(path)"])
        }
    }

    func canFixMain(_ project: Project) -> Bool {
        project.claude != .off && claude?.status == .ready && mainTasks[project.id] == nil
    }

    func fixMain(_ project: Project) {
        guard let check = mainChecks[project.id], canFixMain(project) else { return }
        switch check.phase {
        case .failed, .missing, .rejected, .stopped: startMainFix(project, check: check)
        default: return
        }
    }

    func stopMain(_ project: Project) {
        mainTasks[project.id]?.cancel()
    }

    func rejectMain(_ project: Project) {
        guard var check = mainChecks[project.id], check.phase == .ready else { return }
        check.phase = .rejected
        check.proposal = nil
        setMain(check, project: project)
    }

    func applyMain(_ project: Project) {
        guard var check = mainChecks[project.id], check.phase == .ready, let commands = check.proposal?.commands
        else { return }
        var updated = project
        updated.setup = commands.setup
        updated.test = commands.test
        update(updated)
        check.phase = .passed
        check.commands = commands
        check.lastPassed = commands
        check.pick = false
        check.proposal = nil
        setMain(check, project: updated)
        self.check(updated)
    }

    private func startMainFix(_ project: Project, check: MainCheck) {
        guard let client = client(), let path = claude?.path else { return }
        let failure = check.failedStage.map { check[$0].log.map(\.text).joined(separator: "\n") } ?? ""
        let prompt = CommandPrompt(
            pick: check.pick, branch: project.targetBranch, setup: check.commands.setup, test: check.commands.test,
            failureLog: failure, rules: store.settings.claude.rules ?? localized("settings.rulesDefault"),
            projectRules: project.rules,
            language: FixPrompt.languageName(Bundle.main.preferredLocalizations.first ?? "en"))
        let runner = makeClaudeRunner()
        let directory = store.cloneDirectory(for: project)
        let claude: MainPipeline.Claude = { text, resume, onEvent in
            try await runner.run(
                ClaudeRequest(
                    executable: path, directory: directory, prompt: text, allowedTools: CommandPrompt.allowedTools,
                    schema: CommandPrompt.schema, resume: resume), onEvent: onEvent)
        }
        let pipeline = MainPipeline(project: project, effects: mainEffects(project, client: client))
        let attempts = store.settings.claude.attempts
        let recorder = mainRecorder(project, start: check)
        mainTasks[project.id] = Task {
            let result = await pipeline.fix(prompt, attempts: attempts, claude: claude, recorder)
            setMain(result, project: project)
            mainTasks[project.id] = nil
        }
    }

    private func mainRecorder(_ project: Project, start: MainCheck) -> Recorder<MainCheck> {
        let generation = (mainGenerations[project.id] ?? 0) + 1
        mainGenerations[project.id] = generation
        mainRevisions[project.id] = 0
        return Recorder(start) { [weak self] check, revision in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.mainGenerations[project.id] == generation,
                        revision > (self.mainRevisions[project.id] ?? 0)
                    else { return }
                    self.mainRevisions[project.id] = revision
                    self.mainChecks[project.id] = check
                }
            }
        }
    }

    private func setMain(_ check: MainCheck?, project: Project) {
        mainGenerations[project.id] = (mainGenerations[project.id] ?? 0) + 1
        mainChecks[project.id] = check
        store.saveMainChecks(mainChecks)
    }

    private func runPipeline(_ mr: MergeRequest, _ project: Project, client: GitLabClient) async {
        let pipeline = makePipeline(mr, project, client: client)
        let recorder = recorder(for: mr, project: project, start: run(mr))
        let localDone = Signal()
        stopped.remove(mr.id)
        mrTasks[mr.id] = Task {
            _ = await pipeline.execute(recorder, onLocalDone: { localDone.fire() })
            finish(mr, project, recorder)
        }
        await localDone.wait()
    }

    private func finish(_ mr: MergeRequest, _ project: Project, _ recorder: RunRecorder) {
        var final = recorder.run
        if stopped.remove(mr.id) != nil {
            final = MRRun()
            final.status = .behind(commits: behindCounts[mr.id] ?? 0)
            final.headSHA = nil
        }
        mrTasks[mr.id] = nil
        if final.status == .testsFailed && !mainVerified(at: final.baseSHA, project: project) {
            set(MRRun(), mr: mr, project: project)
            store.saveRuns(runs)
            check(project)
            return
        }
        set(final, mr: mr, project: project)
        store.saveRuns(runs)
        if case .ciFailed(let job) = final.status, let base = final.baseSHA, let client = client() {
            Task {
                if let pipeline = await mainFailure(job: job, sha: base, project: project, client: client) {
                    markMainBroken(project, sha: base, pipeline: pipeline, job: job)
                } else if shouldAutoFix(final, project: project) {
                    startFix(mr)
                }
            }
        } else if shouldAutoFix(final, project: project) {
            startFix(mr)
        }
    }

    private func mainVerified(at sha: String?, project: Project) -> Bool {
        guard let check = mainChecks[project.id] else { return false }
        return check.phase == .passed && check.sha == sha && check.commands == MainCheck.Commands(project)
    }

    private func mainFailure(job: String, sha: String, project: Project, client: GitLabClient) async -> Int? {
        guard let pipeline = try? await client.latestPipeline(project: project.id, sha: sha),
            pipeline.ciStatus == .failed,
            let jobs = try? await client.failedJobs(project: project.id, pipeline: pipeline.id),
            jobs.contains(where: { $0.name == job })
        else { return nil }
        return pipeline.id
    }

    private func markMainBroken(_ project: Project, sha: String, pipeline: Int, job: String) {
        var check = mainChecks[project.id] ?? MainCheck(sha: sha, commands: MainCheck.Commands(project))
        check.sha = sha
        check.phase = .broken
        check.stages = [
            Stage(
                kind: .ci, state: .failed, caption: .mainCiFailed,
                log: [
                    LogLine(text: "pipeline #\(pipeline) · \(project.targetBranch) · \(sha.prefix(7))", kind: .output),
                    LogLine(text: "\(job): failed", kind: .error),
                ])
        ]
        check.finishedAt = Date()
        setMain(check, project: project)
    }

    private func makePipeline(_ mr: MergeRequest, _ project: Project, client: GitLabClient) -> MRPipeline {
        let git = git(for: project)
        let effects =
            makeEffects?(project, git, client) ?? LivePipelineEffects(git: git, gitlab: client, projectID: project.id)
        return MRPipeline(mr: mr, project: project, effects: effects, config: pipelineConfig)
    }

    private func recorder(for mr: MergeRequest, project: Project, start: MRRun) -> RunRecorder {
        let generation = newGeneration(mr.id)
        return RunRecorder(start) { [weak self] run, revision in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(run, generation: generation, revision: revision, mr: mr, project: project)
                }
            }
        }
    }

    private func newGeneration(_ id: String) -> Int {
        let next = (generations[id] ?? 0) + 1
        generations[id] = next
        revisions[id] = 0
        return next
    }

    private func set(_ run: MRRun, mr: MergeRequest, project: Project) {
        let generation = newGeneration(mr.id)
        apply(run, generation: generation, revision: 1, mr: mr, project: project)
    }

    private func apply(_ run: MRRun, generation: Int, revision: Int, mr: MergeRequest, project: Project) {
        guard generation == generations[mr.id], revision > (revisions[mr.id] ?? 0) else { return }
        revisions[mr.id] = revision
        let old = runs[mr.id]?.status ?? .unknown
        let oldFix = runs[mr.id]?.fix?.phase
        runs[mr.id] = run
        if old != run.status || oldFix != run.fix?.phase {
            onStatusChange?(
                StatusChange(
                    mr: mr, project: project, old: old, new: run.status, oldFix: oldFix, newFix: run.fix?.phase))
        }
    }

    static func fixKind(_ status: MRStatus) -> ClaudeFix.Kind? {
        switch status {
        case .testsFailed: .tests
        case .ciFailed: .ci
        case .conflict: .conflict
        default: nil
        }
    }

    func canFix(_ mr: MergeRequest) -> Bool {
        guard let project = project(for: mr), project.claude != .off, claude?.status == .ready, mrTasks[mr.id] == nil,
            !isWaiting(project)
        else { return false }
        let run = run(mr)
        guard Self.fixKind(run.status) != nil else { return false }
        return !(run.fix?.isActive ?? false)
    }

    func shouldAutoFix(_ run: MRRun, project: Project) -> Bool {
        guard project.claude == .inherit, claude?.status == .ready, run.fix == nil, !isWaiting(project) else {
            return false
        }
        let settings = store.settings.claude
        switch Self.fixKind(run.status) {
        case .tests: return settings.onTests
        case .ci: return settings.onCI && run.failedJobID != nil
        case .conflict: return settings.onConflict
        case nil: return false
        }
    }

    func worktree(for mr: MergeRequest, project: Project) -> URL {
        store.fixesDirectory.appendingPathComponent(project.path, isDirectory: true)
            .appendingPathComponent(String(mr.iid), isDirectory: true)
    }

    private func fixPipeline(_ mr: MergeRequest, _ project: Project, client: GitLabClient) -> FixPipeline? {
        guard let path = claude?.path else { return nil }
        let effects = LiveFixEffects(
            clone: git(for: project), worktree: worktree(for: mr, project: project), gitlab: client,
            projectID: project.id, claudePath: path, runner: makeClaudeRunner())
        var config = fixConfig
        config.attempts = store.settings.claude.attempts
        config.autoPush = store.settings.claude.push == .auto
        config.language = FixPrompt.languageName(Bundle.main.preferredLocalizations.first ?? "en")
        config.ciPollInterval = pipelineConfig.ciPollInterval
        config.ciAppearTimeout = pipelineConfig.ciAppearTimeout
        let rules = store.settings.claude.rules ?? localized("settings.rulesDefault")
        return FixPipeline(mr: mr, project: project, effects: effects, rules: rules, config: config)
    }

    private func runFix(_ mr: MergeRequest, _ body: @escaping @MainActor (FixPipeline, RunRecorder) async -> Void) {
        guard let project = project(for: mr), let client = client(), mrTasks[mr.id] == nil,
            let fixer = fixPipeline(mr, project, client: client)
        else { return }
        let recorder = recorder(for: mr, project: project, start: run(mr))
        mrTasks[mr.id] = Task {
            await body(fixer, recorder)
            set(recorder.run, mr: mr, project: project)
            mrTasks[mr.id] = nil
            store.saveRuns(runs)
        }
    }

    func startFix(_ mr: MergeRequest) {
        guard let kind = Self.fixKind(run(mr).status), let project = project(for: mr), project.claude != .off else {
            return
        }
        runFix(mr) { fixer, recorder in _ = await fixer.fix(kind, recorder) }
    }

    func stopFix(_ mr: MergeRequest) {
        mrTasks[mr.id]?.cancel()
    }

    func rejectFix(_ mr: MergeRequest) {
        guard let project = project(for: mr), var current = runs[mr.id], current.fix != nil else { return }
        mrTasks[mr.id]?.cancel()
        current.fix?.phase = .rejected
        current.fix?.files = []
        set(current, mr: mr, project: project)
        store.saveRuns(runs)
        Task { await discardWorktree(mr, project) }
    }

    func pushFix(_ mr: MergeRequest, message: String) {
        runFix(mr) { fixer, recorder in _ = await fixer.push(message: message, recorder) }
    }

    func canRevert(_ mr: MergeRequest) -> Bool {
        guard let fix = run(mr).fix, fix.phase == .pushed, let pushed = fix.pushedSHA, let project = project(for: mr)
        else { return false }
        let known = state(project).mergeRequests.first { $0.id == mr.id }?.sha ?? mr.sha
        return known == pushed || known == fix.baseSHA
    }

    func revertFix(_ mr: MergeRequest) {
        guard let fix = run(mr).fix else { return }
        let failure: MRStatus =
            switch fix.kind {
            case .tests: .testsFailed
            case .ci: .ciFailed(job: fix.job ?? "pipeline")
            case .conflict: .conflict(files: fix.files.map(\.path))
            }
        runFix(mr) { fixer, recorder in _ = await fixer.revert(recorder, failure: failure) }
    }

    func continueInTerminal(_ mr: MergeRequest) {
        guard let project = project(for: mr), var current = runs[mr.id], let fix = current.fix,
            let session = fix.sessionID,
            let claudePath = claude?.path, FileManager.default.fileExists(atPath: fix.worktree)
        else { return }
        mrTasks[mr.id]?.cancel()
        let script = URL(fileURLWithPath: fix.worktree).deletingLastPathComponent().appendingPathComponent(
            "\(mr.iid).command")
        let text =
            "#!/bin/zsh -l\ncd \(ClaudeCLI.quote(fix.worktree)) || exit 1\nexec \(ClaudeCLI.quote(claudePath)) --resume \(ClaudeCLI.quote(session))\n"
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return
        }
        current.fix?.phase = .terminal
        set(current, mr: mr, project: project)
        store.saveRuns(runs)
        openTerminal?(script)
    }

    func recheckFix(_ mr: MergeRequest) {
        runFix(mr) { fixer, recorder in _ = await fixer.recheck(recorder) }
    }

    private func discardWorktree(_ mr: MergeRequest, _ project: Project) async {
        let effects = LiveFixEffects(
            clone: git(for: project), worktree: worktree(for: mr, project: project),
            gitlab: GitLabClient(server: URL(string: "http://localhost")!, token: ""), projectID: project.id,
            claudePath: "")
        await effects.discard()
    }

    func needsRun(_ previous: MRRun?, mr: MergeRequest, base: String) -> Bool {
        guard let previous, previous.status.isFinal else { return true }
        switch previous.status {
        case .branchChanged, .error, .behind:
            return true
        default:
            break
        }
        if (previous.pushedSHA ?? previous.headSHA) != mr.sha { return true }
        return previous.baseSHA != base
    }

    func filter(_ mrs: [MergeRequest], for project: Project) -> [MergeRequest] {
        let settings = store.settings
        return mrs.filter { mr in
            guard mr.targetBranch == project.targetBranch else { return false }
            if settings.skipDrafts && mr.draft { return false }
            let label = settings.skipLabel.trimmingCharacters(in: .whitespaces)
            if settings.skipLabelEnabled && !label.isEmpty && mr.labels.contains(label) { return false }
            return true
        }
    }
}

@MainActor
final class Slots {
    private var used = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire(limit: Int) async {
        if used < limit {
            used += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            used = max(0, used - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFired: Bool { lock.withLock { fired } }

    func fire() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            fired = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if fired { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
