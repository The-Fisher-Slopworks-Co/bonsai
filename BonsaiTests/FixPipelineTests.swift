import Foundation
import Testing
@testable import Bonsai

struct FakeClaude: ClaudeRunning {
    var behavior: @Sendable (ClaudeRequest, Int) throws -> ClaudeResult
    let calls = Counter()

    func run(_ request: ClaudeRequest, onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> ClaudeResult {
        let n = calls.next()
        onEvent(.started(sessionID: "session-1"))
        onEvent(.log(LogLine(text: "Looking at the failure.", kind: .claude)))
        let result = try behavior(request, n)
        onEvent(.finished(result))
        return result
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

func ok(_ summary: String, commit: String = "Fix add") -> ClaudeResult {
    ClaudeResult(sessionID: "session-1", isError: false, summary: summary, commitMessage: commit, notes: [:], errorText: nil)
}

struct FixPipelineTests {
    struct Fixture {
        let repo: TempRepo
        let clone: GitRunner
        let project: Project
        let mr: MergeRequest
        let server: URL
    }

    func fixture(branch: (TempRepo) throws -> Void, main: (TempRepo) throws -> Void) async throws -> Fixture {
        let repo = try await TempRepo()
        try repo.write("add.sh", "echo $(($1 + $2))\n")
        try repo.write("test.sh", "[ \"$(sh add.sh 2 2)\" = 4 ] && echo 'test result: ok' || { echo 'FAIL add 2 2'; exit 1; }\n")
        try repo.write("README.md", "Demo\nVersion: 1\n")
        try await repo.commit("base")
        try await repo.sh("git checkout -q -b feature", in: repo.seed)
        try branch(repo)
        try await repo.commit("feature work")
        try await repo.sh("git checkout -q main", in: repo.seed)
        try repo.write("MAIN.md", "main\n")
        try main(repo)
        try await repo.commit("main moves")
        try await repo.sh("git push -q origin --all", in: repo.seed)
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let sha = try await repo.sh("git rev-parse feature", in: repo.seed)
        let project = Project(id: 1, name: "app", path: "g/app", webURL: URL(string: "https://x")!, cloneURL: URL(fileURLWithPath: repo.origin.path),
                              defaultBranch: "main", targetBranch: "main", setup: "", test: "sh test.sh")
        let mr = MergeRequest(projectID: 1, iid: 7, title: "Feature", author: "me", sourceBranch: "feature", targetBranch: "main",
                              webURL: URL(string: "https://x/7")!, sha: sha, draft: false, labels: [])
        let server = MockURLProtocol.server { request in
            let path = request.url!.path()
            if path.hasSuffix("/pipelines") { return (200, json(#"[{"id": 9, "status": "success", "sha": "x"}]"#)) }
            if path.hasSuffix("/trace") { return (200, Data("lint: src/a.ts unused import\n".utf8)) }
            return (404, Data())
        }
        return Fixture(repo: repo, clone: clone, project: project, mr: mr, server: server)
    }

    func pipeline(_ f: Fixture, claude: FakeClaude, attempts: Int = 2, autoPush: Bool = false) -> FixPipeline {
        let effects = LiveFixEffects(clone: f.clone, worktree: f.repo.root.appendingPathComponent("fixes/g/app/7"),
                                     gitlab: GitLabClient(server: f.server, token: "t", configuration: MockURLProtocol.configuration()),
                                     projectID: 1, claudePath: "/usr/bin/true", runner: claude)
        var config = FixPipeline.Config()
        config.attempts = attempts
        config.autoPush = autoPush
        config.ciPollInterval = 0.01
        return FixPipeline(mr: f.mr, project: f.project, effects: effects, rules: "Minimal changes.", config: config)
    }

    func failedRun(_ status: MRStatus) -> MRRun {
        var run = MRRun()
        run.status = status
        run[.test].state = .failed
        run[.test].log = [LogLine(text: "$ sh test.sh", kind: .command), LogLine(text: "FAIL add 2 2", kind: .output)]
        return run
    }

    func origin(_ f: Fixture, _ ref: String) async throws -> String {
        try await f.repo.sh("git --git-dir=\(f.repo.origin.path) rev-parse \(ref)", in: f.repo.root)
    }

    @Test func testsFixReviewAndPush() async throws {
        let f = try await fixture(branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { try $0.write("CHANGELOG", "x\n") })
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            #expect(request.prompt.contains("FAIL add 2 2"))
            #expect(request.allowedTools.contains("Bash(sh test.sh)"))
            try "echo $(($1 + $2))\n".write(to: request.directory.appendingPathComponent("add.sh"), atomically: true, encoding: .utf8)
            return ok("add вычитал вместо сложения. Исправил на +.", commit: "Fix add to sum arguments")
        }
        let fixer = pipeline(f, claude: claude)
        let recorder = RunRecorder(failedRun(.testsFailed)) { _ in }
        let run = await fixer.fix(.tests, recorder)
        let fix = try #require(run.fix)
        #expect(fix.phase == .ready)
        #expect(fix.summary.contains("Исправил"))
        #expect(fix.commitMessage == "Fix add to sum arguments")
        #expect(fix.files.map(\.path) == ["add.sh"], "\(fix.files.map(\.path))")
        #expect(fix.files[0].added == 1 && fix.files[0].removed == 1)
        #expect(!fix.testsTouched)
        #expect(fix[.claude].caption == .claudeChanged)
        #expect(fix[.claude].detail == "1/1/1")
        #expect(fix[.retest].state == .done)
        #expect(fix.sessionID == "session-1")
        #expect(try await origin(f, "feature") == f.mr.sha)

        let pushed = await fixer.push(message: "Fix add() sum", recorder)
        #expect(pushed.fix?.phase == .pushed)
        #expect(pushed.status == .upToDate(pushed: true))
        let head = try await origin(f, "feature")
        #expect(head == pushed.fix?.pushedSHA)
        let subject = try await f.repo.sh("git --git-dir=\(f.repo.origin.path) log -1 --format=%s feature", in: f.repo.root)
        #expect(subject == "Fix add() sum")
        let behind = try await f.repo.sh("git --git-dir=\(f.repo.origin.path) rev-list --count feature..main", in: f.repo.root)
        #expect(behind == "0")
        #expect(!FileManager.default.fileExists(atPath: fix.worktree))

        let reverted = await fixer.revert(recorder, failure: .testsFailed)
        #expect(reverted.fix?.phase == .reverted)
        #expect(reverted.status == .testsFailed)
        #expect(try await origin(f, "feature") == f.mr.sha)
    }

    @Test func givesUpAfterAttemptsAndLeavesBranch() async throws {
        let f = try await fixture(branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { try $0.write("CHANGELOG", "x\n") })
        defer { f.repo.remove() }
        let claude = FakeClaude { request, n in
            if n == 2 { #expect(request.resume == "session-1"); #expect(request.prompt.contains("still fail")) }
            return ok("Не помогло.")
        }
        let run = await pipeline(f, claude: claude).fix(.tests, RunRecorder(failedRun(.testsFailed)) { _ in })
        #expect(claude.calls.count == 2)
        let fix = try #require(run.fix)
        #expect(fix.phase == .gaveUp)
        #expect(fix[.claude].state == .failed)
        #expect(fix[.claude].caption == .claudeFailed)
        #expect(fix[.claude].detail == "2")
        #expect(FileManager.default.fileExists(atPath: fix.worktree))
        #expect(try await origin(f, "feature") == f.mr.sha)
    }

    @Test func conflictFromBothSidesIsPushedAutomatically() async throws {
        let f = try await fixture(branch: { try $0.write("README.md", "Demo\nVersion: 2-branch\n") },
                                  main: { try $0.write("README.md", "Demo\nVersion: 2-main\n") })
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            #expect(request.prompt.contains("README.md"))
            #expect(request.allowedTools.contains("Bash(git add *)"))
            try "Demo\nVersion: 2-main\nVersion: 2-branch\n".write(to: request.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            return ClaudeResult(sessionID: "session-1", isError: false, summary: "Оставил обе строки.", commitMessage: "",
                                notes: ["README.md": "Обе версии."], errorText: nil)
        }
        let run = await pipeline(f, claude: claude, autoPush: true).fix(.conflict, RunRecorder(MRRun()) { _ in })
        let fix = try #require(run.fix)
        #expect(fix.phase == .pushed)
        #expect(!fix.ownCode)
        #expect(fix.files.first?.path == "README.md")
        #expect(fix.files.first?.conflicts.first?.source == .both)
        #expect(fix.files.first?.note == "Обе версии.")
        #expect(fix[.claude].caption == .claudeResolved)
        #expect(fix[.continueRebase].state == .done)
        let readme = try await f.repo.sh("git --git-dir=\(f.repo.origin.path) show feature:README.md", in: f.repo.root)
        #expect(readme == "Demo\nVersion: 2-main\nVersion: 2-branch")
        let subject = try await f.repo.sh("git --git-dir=\(f.repo.origin.path) log -1 --format=%s feature", in: f.repo.root)
        #expect(subject == "feature work")
    }

    @Test func conflictWithOwnCodeWaitsForReviewEvenInAutoMode() async throws {
        let f = try await fixture(branch: { try $0.write("README.md", "Demo\nVersion: 2-branch\n") },
                                  main: { try $0.write("README.md", "Demo\nVersion: 2-main\n") })
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            try "Demo\nVersion: 3\n".write(to: request.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            return ok("Свой вариант.", commit: "")
        }
        let run = await pipeline(f, claude: claude, autoPush: true).fix(.conflict, RunRecorder(MRRun()) { _ in })
        #expect(run.fix?.phase == .ready)
        #expect(run.fix?.ownCode == true)
        #expect(try await origin(f, "feature") == f.mr.sha)
        await pipeline(f, claude: claude).effects.discard()
    }

    @Test func ciFixReadsJobLog() async throws {
        let f = try await fixture(branch: { try $0.write("lint.txt", "unused\n") }, main: { _ in })
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            #expect(request.prompt.contains("lint: src/a.ts unused import"))
            #expect(request.prompt.contains("CI job `lint`"))
            try FileManager.default.removeItem(at: request.directory.appendingPathComponent("lint.txt"))
            return ok("Убрал лишнее.", commit: "Remove unused file")
        }
        var failed = MRRun()
        failed.status = .ciFailed(job: "lint")
        failed.failedJobID = 70
        let run = await pipeline(f, claude: claude).fix(.ci, RunRecorder(failed) { _ in })
        #expect(run.fix?.phase == .ready)
        #expect(run.fix?.job == "lint")
        #expect(run.fix?.files.first?.removed == 1)
        await pipeline(f, claude: claude).effects.discard()
    }

    @Test func testFileChangeIsFlagged() async throws {
        let f = try await fixture(branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { _ in })
        defer { f.repo.remove() }
        let claude = FakeClaude { request, _ in
            try "echo 'test result: ok'\n".write(to: request.directory.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: request.directory.appendingPathComponent("tests"), withIntermediateDirectories: true)
            try "x\n".write(to: request.directory.appendingPathComponent("tests/new_test.sh"), atomically: true, encoding: .utf8)
            return ok("Поменял тест.")
        }
        let run = await pipeline(f, claude: claude).fix(.tests, RunRecorder(failedRun(.testsFailed)) { _ in })
        #expect(run.fix?.phase == .ready)
        #expect(run.fix?.testsTouched == true)
        await pipeline(f, claude: claude).effects.discard()
    }

    @Test func stopDiscardsWorktree() async throws {
        let f = try await fixture(branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { _ in })
        defer { f.repo.remove() }
        let claude = FakeClaude { _, _ in
            Thread.sleep(forTimeInterval: 0.3)
            return ok("…")
        }
        let fixer = pipeline(f, claude: claude)
        let recorder = RunRecorder(failedRun(.testsFailed)) { _ in }
        var fix = f.project
        fix.test = "sleep 20"
        let slow = FixPipeline(mr: f.mr, project: fix, effects: fixer.effects, rules: "", config: fixer.config)
        let task = Task { await slow.fix(.tests, recorder) }
        while recorder.run.fix?[.retest].state != .running { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        let run = await task.value
        #expect(run.fix?.phase == .stopped)
        #expect(!FileManager.default.fileExists(atPath: fixer.effects.worktree.path))
    }

    @Test func claudeErrorGivesUp() async throws {
        let f = try await fixture(branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { _ in })
        defer { f.repo.remove() }
        let claude = FakeClaude { _, _ in
            ClaudeResult(sessionID: nil, isError: true, summary: "", commitMessage: "", notes: [:], errorText: "Not logged in")
        }
        let run = await pipeline(f, claude: claude).fix(.tests, RunRecorder(failedRun(.testsFailed)) { _ in })
        #expect(run.fix?.phase == .gaveUp)
        #expect(run.fix?[.claude].log.contains { $0.text.contains("Not logged in") } == true)
    }
}
