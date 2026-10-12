// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

protocol FixEffects: Sendable {
    var worktree: URL { get }
    func prepare(branch: String, log: @escaping LogSink) async throws
    func rebase(onto ref: String, log: @escaping LogSink) async throws -> RebaseResult
    func continueRebase(log: @escaping LogSink) async throws -> RebaseResult
    func copy(_ paths: [String], from localCopy: String, log: @escaping LogSink) async throws
    func read(_ path: String) -> String?
    func run(_ command: String, log: @escaping LogSink) async throws -> (ok: Bool, output: String)
    func claude(prompt: String, tools: [String], resume: String?, onEvent: @escaping @Sendable (ClaudeEvent) -> Void)
        async throws -> ClaudeResult
    func diff() async throws -> String
    var isDirty: Bool { get async throws }
    func commit(_ message: String, amend: Bool) async throws
    func head() async throws -> String
    func push(_ branch: String, sha: String, expected: String, log: @escaping LogSink) async throws -> PushResult
    func jobLog(_ job: Int) async throws -> String
    func pipeline(sha: String) async throws -> CIPipeline?
    func failedJob(pipeline: Int) async throws -> CIJob?
    func discard() async
    func sleep(_ seconds: TimeInterval) async throws
}

struct LiveFixEffects: FixEffects {
    var clone: GitRunner
    var worktree: URL
    var gitlab: GitLabClient
    var projectID: Int
    var claudePath: String
    var runner: any ClaudeRunning = LiveClaudeRunner()
    var directories: [String] = []
    var shell = "/bin/zsh"

    private var git: GitRunner { GitRunner(directory: worktree, auth: clone.auth, identity: clone.identity) }

    func prepare(branch: String, log: @escaping LogSink) async throws {
        await discard()
        try await clone.fetch()
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await clone.checked(
            ["worktree", "add", "--force", "--detach", worktree.path, "origin/\(branch)"], onLine: output(log))
    }

    func rebase(onto ref: String, log: @escaping LogSink) async throws -> RebaseResult {
        let result = try await git.run(["rebase", ref], onLine: output(log))
        if result.succeeded { return .ok }
        return try await conflicts(
            or: GitError(command: "git rebase \(ref)", status: result.status, output: result.output))
    }

    func continueRebase(log: @escaping LogSink) async throws -> RebaseResult {
        try await git.checked(["add", "-A"])
        let result = try await git.run(["-c", "core.editor=true", "rebase", "--continue"], onLine: output(log))
        if result.succeeded { return .ok }
        return try await conflicts(
            or: GitError(command: "git rebase --continue", status: result.status, output: result.output))
    }

    func copy(_ paths: [String], from localCopy: String, log: @escaping LogSink) async throws {
        try await git.copy(paths, from: localCopy, log: log)
    }

    private func conflicts(or error: GitError) async throws -> RebaseResult {
        let files = try await git.checked(["diff", "--name-only", "--diff-filter=U"]).split(separator: "\n").map(
            String.init)
        guard !files.isEmpty else { throw error }
        return .conflict(files: files)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: worktree.appendingPathComponent(path), encoding: .utf8)
    }

    func run(_ command: String, log: @escaping LogSink) async throws -> (ok: Bool, output: String) {
        let result = try await ProcessRunner.run(shell, ["-lc", command], in: worktree, onLine: output(log))
        return (result.succeeded, result.output)
    }

    func claude(prompt: String, tools: [String], resume: String?, onEvent: @escaping @Sendable (ClaudeEvent) -> Void)
        async throws -> ClaudeResult
    {
        let request = ClaudeRequest(
            executable: claudePath, directory: worktree, prompt: prompt, allowedTools: tools,
            schema: FixPrompt.schema, resume: resume, directories: directories)
        return try await runner.run(request, onEvent: onEvent)
    }

    func diff() async throws -> String {
        try await git.checked(["add", "-A", "-N"])
        return try await git.run([
            "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "diff", "--no-color", "--no-ext-diff",
            "--src-prefix=a/", "--dst-prefix=b/", "HEAD",
        ]).output
    }

    var isDirty: Bool {
        get async throws { !(try await git.checked(["status", "--porcelain"]).isEmpty) }
    }

    func commit(_ message: String, amend: Bool) async throws {
        try await git.checked(["add", "-A"])
        if amend {
            try await git.checked(["commit", "--amend", "--no-edit", "--quiet"])
        } else {
            try await git.checked(["commit", "--quiet", "-m", message])
        }
    }

    func head() async throws -> String {
        try await git.revParse("HEAD")
    }

    func push(_ branch: String, sha: String, expected: String, log: @escaping LogSink) async throws -> PushResult {
        let result = try await clone.run(
            ["push", "--force-with-lease=refs/heads/\(branch):\(expected)", "origin", "\(sha):refs/heads/\(branch)"],
            onLine: output(log))
        if result.succeeded { return .ok }
        if LivePipelineEffects.isLeaseRejection(result.output) { return .rejected }
        return .failed(result.output.split(separator: "\n").last.map(String.init) ?? "git push")
    }

    func jobLog(_ job: Int) async throws -> String {
        try await gitlab.jobLog(project: projectID, job: job)
    }

    func pipeline(sha: String) async throws -> CIPipeline? {
        guard let pipeline = try await gitlab.latestPipeline(project: projectID, sha: sha) else { return nil }
        return CIPipeline(id: pipeline.id, status: pipeline.ciStatus)
    }

    func failedJob(pipeline: Int) async throws -> CIJob? {
        try await gitlab.failedJobs(project: projectID, pipeline: pipeline).first.map {
            CIJob(id: $0.id, name: $0.name)
        }
    }

    func discard() async {
        _ = try? await clone.run(["worktree", "remove", "--force", worktree.path])
        try? FileManager.default.removeItem(at: worktree)
        _ = try? await clone.run(["worktree", "prune"])
    }

    func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func output(_ log: @escaping LogSink) -> @Sendable (String) -> Void {
        { line in log(LogLine(text: line, kind: .output)) }
    }
}
