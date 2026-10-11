import Foundation
import Testing

@testable import Bonsai

@MainActor
struct WorkspaceTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-ws-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    nonisolated static func mrJSON(
        _ iid: Int, branch: String, sha: String, target: String = "main", draft: Bool = false, labels: [String] = []
    ) -> String {
        let labelList = labels.map { "\"\($0)\"" }.joined(separator: ",")
        return
            #"{"iid": \#(iid), "project_id": 9, "title": "MR \#(iid)", "author": {"username": "me", "name": "Me"}, "source_branch": "\#(branch)", "target_branch": "\#(target)", "web_url": "https://x/mr/\#(iid)", "sha": "\#(sha)", "draft": \#(draft), "labels": [\#(labelList)], "source_project_id": 9}"#
    }

    final class FakeGitLab: @unchecked Sendable {
        let lock = NSLock()
        var mrs: [String] = []
        var pipelineStatus = "success"
        func handler() -> MockURLProtocol.Handler {
            { [self] request in
                let path = request.url!.path()
                if path.hasSuffix("/merge_requests") {
                    return (200, json("[" + lock.withLock { mrs }.joined(separator: ",") + "]"))
                }
                if path.hasSuffix("/pipelines") {
                    let sha =
                        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
                            $0.name == "sha"
                        }?.value ?? ""
                    return (
                        200, json(#"[{"id": 5, "status": "\#(lock.withLock { pipelineStatus })", "sha": "\#(sha)"}]"#)
                    )
                }
                if path.hasSuffix("/retry") { return (201, json(#"{"id": 5, "status": "pending", "sha": ""}"#)) }
                if path.hasSuffix("/jobs") { return (200, json(#"[{"id": 50, "name": "lint", "status": "failed"}]"#)) }
                return (404, Data())
            }
        }
    }

    struct Fixture {
        let repo: TempRepo
        let store: Store
        let workspace: Workspace
        let gitlab: FakeGitLab
        let project: Project
    }

    func fixture(test: String = "true", branches: [String] = ["feature"]) async throws -> Fixture {
        let repo = try await TempRepo()
        for branch in branches {
            try await repo.sh("git checkout -q -b \(branch) main", in: repo.seed)
            try repo.write("\(branch).txt", "x\n")
            try await repo.commit(branch)
        }
        try await repo.sh("git checkout -q main", in: repo.seed)
        try repo.write("main.txt", "m\n")
        try await repo.commit("main moves")
        try await repo.sh("git push -q origin --all", in: repo.seed)

        let gitlab = FakeGitLab()
        var mrs: [String] = []
        for (i, branch) in branches.enumerated() {
            let sha = try await repo.sh("git rev-parse \(branch)", in: repo.seed)
            mrs.append(Self.mrJSON(i + 1, branch: branch, sha: sha))
        }
        gitlab.mrs = mrs
        let server = MockURLProtocol.server(gitlab.handler())
        let store = Store(directory: dir, keychain: keychain)
        try store.signIn(Account(server: server, username: "me", name: "Me"), token: "t")
        let workspace = Workspace(store: store, configuration: { MockURLProtocol.configuration() })
        workspace.pipelineConfig.ciPollInterval = 0.05
        let project = Project(
            id: 9, name: "app", path: "g/app", webURL: URL(string: "https://x/g/app")!,
            cloneURL: URL(fileURLWithPath: repo.origin.path), defaultBranch: "main", targetBranch: "main",
            setup: "", test: test)
        return Fixture(repo: repo, store: store, workspace: workspace, gitlab: gitlab, project: project)
    }

    @Test func addClonesRunsAndPushes() async throws {
        let f = try await fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        #expect(f.workspace.state(f.project).loading == .loading)
        await f.workspace.waitUntilIdle()

        let state = f.workspace.state(f.project)
        #expect(state.loading == .loaded)
        #expect(state.mergeRequests.map(\.iid) == [1])
        let mr = state.mergeRequests[0]
        let run = f.workspace.run(mr)
        #expect(run.status == .upToDate(pushed: true))
        #expect(run.stages.map(\.state) == [.done, .skipped, .done, .done, .done])
        let originFeature = try await f.repo.sh(
            "git --git-dir=\(f.repo.origin.path) rev-parse feature", in: f.repo.root)
        #expect(originFeature == run.pushedSHA)
        #expect(f.store.loadRuns()[mr.id]?.status == .upToDate(pushed: true))
    }

    @Test func unchangedMRIsNotRerun() async throws {
        let f = try await fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        let mr = f.workspace.state(f.project).mergeRequests[0]
        let pushed = try #require(f.workspace.run(mr).pushedSHA)
        f.gitlab.mrs = [Self.mrJSON(1, branch: "feature", sha: pushed)]
        let finished = f.workspace.run(mr).finishedAt
        f.workspace.check(f.project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).finishedAt == finished)
        #expect(f.workspace.run(mr).status == .upToDate(pushed: true))
    }

    @Test func failingTestsKeepStatusUntilForced() async throws {
        let f = try await fixture(test: "echo 'test result: FAILED'; exit 1")
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        let mr = f.workspace.state(f.project).mergeRequests[0]
        #expect(f.workspace.run(mr).status == .testsFailed)
        let first = f.workspace.run(mr).finishedAt

        f.workspace.check(f.project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).finishedAt == first)

        f.workspace.start(mr)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).status == .testsFailed)
        #expect(f.workspace.run(mr).finishedAt != first)
    }

    @Test func statusChangesAreReported() async throws {
        let f = try await fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        var seen: [MRStatus] = []
        f.workspace.onStatusChange = { seen.append($0.new) }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        #expect(seen.first == .behind(commits: 1))
        #expect(seen.contains(.running(.test, attempt: 1)))
        #expect(seen.last == .upToDate(pushed: true))
    }

    @Test func stopReturnsToBehind() async throws {
        let f = try await fixture(test: "sleep 30")
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        var mr: MergeRequest?
        for _ in 0..<200 {
            mr = f.workspace.state(f.project).mergeRequests.first
            if let mr, f.workspace.run(mr).status == .running(.test, attempt: 1) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let current = try #require(mr)
        #expect(f.workspace.run(current).status == .running(.test, attempt: 1))
        f.workspace.stop(current)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(current).status == .behind(commits: 1))
        #expect(f.workspace.run(current).stages.allSatisfy { $0.state == .pending })
        let originFeature = try await f.repo.sh(
            "git --git-dir=\(f.repo.origin.path) rev-parse feature", in: f.repo.root)
        #expect(originFeature == current.sha)
    }

    @Test func ciFailureAndRerun() async throws {
        let f = try await fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.gitlab.pipelineStatus = "failed"
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        let mr = f.workspace.state(f.project).mergeRequests[0]
        #expect(f.workspace.run(mr).status == .ciFailed(job: "lint"))
        #expect(MRPresentation(f.workspace.run(mr)).actions == [.rerunCI, .fix])

        f.gitlab.pipelineStatus = "success"
        f.workspace.rerunCI(mr)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).status == .upToDate(pushed: true))
    }

    @Test func filtersDraftsLabelsAndOtherTargets() async throws {
        let f = try await fixture(branches: [])
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.gitlab.mrs = [
            Self.mrJSON(1, branch: "a", sha: "1"), Self.mrJSON(2, branch: "b", sha: "2", draft: true),
            Self.mrJSON(3, branch: "c", sha: "3", labels: ["no-rebase"]),
            Self.mrJSON(4, branch: "d", sha: "4", target: "release"),
        ]
        let mrs = try await f.workspace.client()!.mergeRequests(project: 9, scope: .mine)
        #expect(f.workspace.filter(mrs, for: f.project).map(\.iid) == [1])
        f.store.settings.skipDrafts = false
        f.store.settings.skipLabelEnabled = false
        #expect(f.workspace.filter(mrs, for: f.project).map(\.iid) == [1, 2, 3])
    }

    @Test func needsRunRules() throws {
        let store = Store(directory: dir, keychain: keychain)
        let workspace = Workspace(store: store)
        let mr = PipelineTests.mr
        #expect(workspace.needsRun(nil, mr: mr, base: "b"))
        var run = MRRun()
        run.status = .upToDate(pushed: true)
        run.headSHA = "old"
        run.pushedSHA = mr.sha
        run.baseSHA = "b"
        #expect(!workspace.needsRun(run, mr: mr, base: "b"))
        #expect(workspace.needsRun(run, mr: mr, base: "b2"))
        run.pushedSHA = nil
        #expect(workspace.needsRun(run, mr: mr, base: "b"))
        run.headSHA = mr.sha
        run.status = .conflict(files: ["a"])
        #expect(!workspace.needsRun(run, mr: mr, base: "b"))
        run.status = .branchChanged
        #expect(workspace.needsRun(run, mr: mr, base: "b"))
        run.status = .running(.test, attempt: 1)
        #expect(workspace.needsRun(run, mr: mr, base: "b"))
    }
}

@MainActor
struct SlotsTests {
    @Test func limitsConcurrency() async {
        let slots = Slots()
        await slots.acquire(limit: 2)
        await slots.acquire(limit: 2)
        var third = false
        let waiter = Task {
            await slots.acquire(limit: 2)
            third = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!third)
        slots.release()
        await waiter.value
        #expect(third)
    }
}

@MainActor
struct SchedulerTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-sched-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    @Test func pauseForAnHourAndResume() {
        let store = Store(directory: dir, keychain: keychain)
        let scheduler = Scheduler(workspace: Workspace(store: store))
        #expect(!scheduler.isPaused)
        scheduler.pauseForHour()
        #expect(scheduler.isPaused)
        let until = try? #require(scheduler.pausedUntil)
        #expect(abs((until ?? Date()).timeIntervalSinceNow - 3600) < 5)
        #expect(Store(directory: dir, keychain: keychain).pausedUntil != nil)
        scheduler.resume()
        #expect(!scheduler.isPaused)
    }

    @Test func expiredPauseIsIgnored() {
        let store = Store(directory: dir, keychain: keychain)
        store.pausedUntil = Date().addingTimeInterval(-10)
        #expect(!Scheduler(workspace: Workspace(store: store)).isPaused)
    }

    @Test func manualIntervalHasNoTimer() {
        let store = Store(directory: dir, keychain: keychain)
        let scheduler = Scheduler(workspace: Workspace(store: store))
        store.settings.interval = .manual
        scheduler.reschedule()
        #expect(scheduler.nextCheck == nil)
        store.settings.interval = .every15
        scheduler.reschedule()
        #expect(abs((scheduler.nextCheck ?? .distantPast).timeIntervalSinceNow - 900) < 5)
        scheduler.stop()
    }
}
