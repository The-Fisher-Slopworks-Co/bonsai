import Foundation
import Testing

@testable import Bonsai

@MainActor
struct WorkspaceFixTests {
    func fixture(claude: FakeClaude, configure: (Store) -> Void = { _ in }) async throws -> WorkspaceTests.Fixture {
        let base = WorkspaceTests()
        let f = try await base.fixture(test: "[ -f fixed ] || { echo 'FAIL needs fixed'; exit 1; }")
        f.workspace.claude = ClaudeCLI.Check(path: "/usr/bin/true", status: .ready)
        f.workspace.makeClaudeRunner = { claude }
        f.workspace.fixConfig.ciPollInterval = 0.05
        configure(f.store)
        return f
    }

    static let fixing = FakeClaude { request, _ in
        try "yes\n".write(to: request.directory.appendingPathComponent("fixed"), atomically: true, encoding: .utf8)
        return ok("Добавил файл fixed.", commit: "Add fixed marker")
    }

    func waitFor(_ f: WorkspaceTests.Fixture, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        await f.workspace.waitUntilIdle()
    }

    @Test func autoFixAfterTestsFailThenPush() async throws {
        var notes: [String] = []
        let f = try await fixture(claude: Self.fixing)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.onStatusChange = { change in
            if let note = NotificationRules.note(for: change, settings: NotificationSettings()) {
                notes.append(note.title)
            }
        }
        f.workspace.add(f.project)
        let mr = try await firstMR(f)
        try await waitFor(f) { f.workspace.run(mr).fix?.phase == .ready }
        let run = f.workspace.run(mr)
        #expect(run.status == .testsFailed)
        #expect(run.fix?.phase == .ready)
        #expect(MRPresentation(run).group == .decide)
        #expect(MRPresentation(run).actions == [.reject, .view])
        #expect(notes.contains("notify.testsFailed"))
        #expect(notes.contains("notify.claudeReady"))

        f.workspace.check(f.project)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).fix?.phase == .ready)

        f.workspace.pushFix(mr, message: "Add fixed marker")
        await f.workspace.waitUntilIdle()
        let pushed = f.workspace.run(mr)
        #expect(pushed.fix?.phase == .pushed)
        #expect(pushed.status == .upToDate(pushed: true))
        #expect(MRPresentation(pushed).statusText == localized("fix.fixedByClaude"))
        let origin = try await f.repo.sh("git --git-dir=\(f.repo.origin.path) rev-parse feature", in: f.repo.root)
        #expect(origin == pushed.fix?.pushedSHA)
        #expect(f.workspace.canRevert(mr))
    }

    @Test func manualModeOffersFixButton() async throws {
        let f = try await fixture(claude: Self.fixing) { $0.settings.claude.onTests = false }
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        let mr = try await firstMR(f)
        #expect(f.workspace.run(mr).status == .testsFailed)
        #expect(f.workspace.run(mr).fix == nil)
        #expect(f.workspace.canFix(mr))
        #expect(MRPresentation(f.workspace.run(mr)).actions == [.retry, .fix])

        f.workspace.startFix(mr)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).fix?.phase == .ready)
        f.workspace.rejectFix(mr)
        #expect(f.workspace.run(mr).fix?.phase == .rejected)
        #expect(MRPresentation(f.workspace.run(mr)).bannerBody == localized("fix.bn.rejected"))
        #expect(MRPresentation(f.workspace.run(mr)).group == .attention)
    }

    @Test func claudeOffForProjectHidesFix() async throws {
        let f = try await fixture(claude: Self.fixing)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        var project = f.project
        project.claude = .off
        f.workspace.add(project)
        await f.workspace.waitUntilIdle()
        let mr = try await firstMR(f)
        #expect(f.workspace.run(mr).fix == nil)
        #expect(!f.workspace.canFix(mr))
    }

    @Test func gaveUpThenTerminalThenRecheck() async throws {
        let stubborn = FakeClaude { _, _ in ok("Не вышло.") }
        let f = try await fixture(claude: stubborn)
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        var opened: URL?
        f.workspace.openTerminal = { opened = $0 }
        f.workspace.add(f.project)
        let mr = try await firstMR(f)
        try await waitFor(f) { f.workspace.run(mr).fix?.phase == .gaveUp }
        #expect(f.workspace.run(mr).fix?.phase == .gaveUp)
        #expect(MRPresentation(f.workspace.run(mr)).actions == [.terminal, .retryFix])

        f.workspace.continueInTerminal(mr)
        let script = try #require(opened)
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("--resume 'session-1'"))
        #expect(f.workspace.run(mr).fix?.phase == .terminal)
        #expect(MRPresentation(f.workspace.run(mr)).group == .decide)

        let worktree = try #require(f.workspace.run(mr).fix?.worktree)
        try "yes\n".write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent("fixed"), atomically: true, encoding: .utf8)
        f.workspace.recheckFix(mr)
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.run(mr).fix?.phase == .ready)
        #expect(f.workspace.run(mr).fix?.files.map(\.path) == ["fixed"])
    }

    private func firstMR(_ f: WorkspaceTests.Fixture) async throws -> MergeRequest {
        for _ in 0..<200 {
            if let mr = f.workspace.state(f.project).mergeRequests.first { return mr }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ClaudeError(message: "no MR")
    }
}
