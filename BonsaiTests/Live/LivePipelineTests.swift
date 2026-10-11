import Foundation
import Testing

@testable import Bonsai

@Suite(.serialized, .enabled(if: LiveGitLab.isAvailable, "local GitLab is not running"))
struct LivePipelineTests {
    @Test(.timeLimit(.minutes(10)))
    func seededMergeRequestsReachExpectedStatuses() async throws {
        let name = "e2e-pipeline-\(UUID().uuidString.prefix(6).lowercased())"
        let id = try await LiveGitLab.seed(name)
        let root = URL(fileURLWithPath: "/tmp/bonsai-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await LiveGitLab.project(id)
        let gitlab = LiveGitLab.client()
        let auth = GitAuth(token: try #require(LiveGitLab.token), caFile: nil, server: LiveGitLab.server)
        let git = GitRunner(directory: root.appendingPathComponent(project.path), auth: auth)
        try await git.clone(project.cloneURL)
        let mrs = try await gitlab.mergeRequests(project: id, scope: .mine)
        #expect(mrs.count == 3)

        var config = MRPipeline.Config()
        config.ciPollInterval = 3
        var results: [String: MRRun] = [:]
        for mr in mrs.sorted(by: { $0.iid < $1.iid }) {
            let effects = LivePipelineEffects(git: git, gitlab: gitlab, projectID: id)
            let recorder = RunRecorder(MRRun()) { _ in }
            results[mr.sourceBranch] = await MRPipeline(mr: mr, project: project, effects: effects, config: config)
                .execute(recorder)
        }

        let behind = try #require(results["feature/behind"])
        #expect(behind.status == .upToDate(pushed: true))
        #expect(behind.stages.map(\.state) == [.done, .done, .done, .done, .done])
        let conflict = try #require(results["feature/conflict"])
        #expect(conflict.status == .conflict(files: ["README.md"]))
        let failing = try #require(results["feature/failing-test"])
        #expect(failing.status == .testsFailed)
        #expect(failing[.test].log.contains { $0.text.contains("FAIL add 2 2") })

        let pushed = try #require(behind.pushedSHA)
        try await git.fetch()
        #expect(try await git.revParse("origin/feature/behind") == pushed)
        #expect(try await git.behind("origin/feature/behind", base: "origin/main") == 0)
        #expect(
            try await git.revParse("origin/feature/conflict")
                == mrs.first { $0.sourceBranch == "feature/conflict" }?.sha)
        #expect(
            try await git.revParse("origin/feature/failing-test")
                == mrs.first { $0.sourceBranch == "feature/failing-test" }?.sha)

        let mr = try #require(
            try await gitlab.mergeRequests(project: id, scope: .mine).first { $0.sourceBranch == "feature/behind" })
        let again = await MRPipeline(
            mr: mr, project: project, effects: LivePipelineEffects(git: git, gitlab: gitlab, projectID: id),
            config: config
        )
        .execute(RunRecorder(MRRun()) { _ in })
        #expect(again.status == .upToDate(pushed: false))
        #expect(again[.rebase].caption == .notNeeded)
        await LiveGitLab.deleteProject(id)
    }

    @Test(.timeLimit(.minutes(5)))
    func leaseRejectsWhenBranchMovesAndRestartSucceeds() async throws {
        let name = "e2e-lease-\(UUID().uuidString.prefix(6).lowercased())"
        let id = try await LiveGitLab.seed(name)
        let root = URL(fileURLWithPath: "/tmp/bonsai-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await LiveGitLab.project(id)
        let gitlab = LiveGitLab.client()
        let auth = GitAuth(token: try #require(LiveGitLab.token), caFile: nil, server: LiveGitLab.server)
        let git = GitRunner(directory: root.appendingPathComponent("clone"), auth: auth)
        try await git.clone(project.cloneURL)
        let other = GitRunner(directory: root.appendingPathComponent("other"), auth: auth)
        try await other.clone(project.cloneURL)
        let mr = try #require(
            try await gitlab.mergeRequests(project: id, scope: .mine).first { $0.sourceBranch == "feature/behind" })

        var changed = project
        changed.test = """
            if [ ! -f /tmp/\(name).done ]; then touch /tmp/\(name).done; cd \(other.directory.path) && git checkout -q feature/behind \
            && echo x > X.md && git add X.md && git -c user.name=O -c user.email=o@x -c commit.gpgsign=false commit -qm other \
            && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'oauth2:\(LiveGitLab.token!)' | base64)" git push -q origin feature/behind; fi; sh tests/run.sh
            """
        defer { try? FileManager.default.removeItem(atPath: "/tmp/\(name).done") }
        var config = MRPipeline.Config()
        config.ciPollInterval = 3
        let run = await MRPipeline(
            mr: mr, project: changed, effects: LivePipelineEffects(git: git, gitlab: gitlab, projectID: id),
            config: config
        )
        .execute(RunRecorder(MRRun()) { _ in })
        #expect(run.attempt == 2)
        #expect(run.status == .upToDate(pushed: true))
        try await git.fetch()
        let log = try await git.checked(["log", "--format=%s", "origin/feature/behind"])
        #expect(log.contains("other"))
        await LiveGitLab.deleteProject(id)
    }
}
