// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct LivePipelineEffects: PipelineEffects {
    var git: GitRunner
    var gitlab: GitLabClient
    var projectID: Int
    var shell = "/bin/zsh"

    func fetch(log: @escaping LogSink) async throws {
        try await git.checked(["fetch", "--prune", "--no-tags", "origin"], onLine: output(log))
    }

    func sha(_ ref: String) async throws -> String {
        try await git.revParse(ref)
    }

    func behind(head: String, base: String) async throws -> Int {
        try await git.behind(head, base: base)
    }

    func checkout(_ branch: String, log: @escaping LogSink) async throws {
        if FileManager.default.fileExists(atPath: git.directory.appendingPathComponent(".git/rebase-merge").path)
            || FileManager.default.fileExists(atPath: git.directory.appendingPathComponent(".git/rebase-apply").path)
        {
            try await git.run(["rebase", "--abort"])
        }
        try await git.checked(
            ["checkout", "--quiet", "--force", "-B", branch, "origin/\(branch)"], onLine: output(log))
        try await git.checked(["clean", "-fdq"])
    }

    func rebase(onto ref: String, log: @escaping LogSink) async throws -> RebaseResult {
        let result = try await git.run(["rebase", ref], onLine: output(log))
        if result.succeeded { return .ok }
        let files = try await git.checked(["diff", "--name-only", "--diff-filter=U"])
            .split(separator: "\n").map(String.init)
        guard !files.isEmpty else {
            throw GitError(command: "git rebase \(ref)", status: result.status, output: result.output)
        }
        return .conflict(files: files)
    }

    func abortRebase(log: @escaping LogSink) async {
        _ = try? await git.run(["rebase", "--abort"], onLine: output(log))
    }

    func run(_ command: String, log: @escaping LogSink) async throws -> Bool {
        let result = try await ProcessRunner.run(shell, ["-lc", command], in: git.directory, onLine: output(log))
        return result.succeeded
    }

    func head() async throws -> String {
        try await git.revParse("HEAD")
    }

    func push(_ branch: String, expected: String, log: @escaping LogSink) async throws -> PushResult {
        let result = try await git.run(
            ["push", "--force-with-lease=refs/heads/\(branch):\(expected)", "origin", "HEAD:refs/heads/\(branch)"],
            onLine: output(log))
        if result.succeeded { return .ok }
        if Self.isLeaseRejection(result.output) { return .rejected }
        let last =
            result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("error: failed to push") } ?? "git push"
        return .failed(last)
    }

    static func isLeaseRejection(_ output: String) -> Bool {
        output.contains("stale info") || output.contains("(fetch first)") || output.contains("non-fast-forward")
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

    func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func output(_ log: @escaping LogSink) -> @Sendable (String) -> Void {
        { line in log(LogLine(text: line, kind: .output)) }
    }
}
