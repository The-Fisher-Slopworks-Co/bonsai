import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Bonsai

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct SnapshotTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-snap-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    func workspace(projects: [Project] = []) throws -> Workspace {
        let server = MockURLProtocol.server(AddProjectModelTests.handler)
        let store = Store(directory: dir, keychain: keychain)
        try store.signIn(Account(server: server, username: "me", name: "Me"), token: "t")
        store.projects = projects
        return Workspace(store: store, configuration: { MockURLProtocol.configuration() })
    }

    @Test func connect() async throws {
        let store = Store(directory: dir, keychain: keychain)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try await Snapshot.save("connect-\(appearance == .aqua ? "light" : "dark")", appearance: appearance, ConnectView(store: store))
        }
    }

    @Test func projectsEmpty() async throws {
        let ws = try workspace()
        defer { ws.store.signOut() }
        let app = AppModel(store: ws.store)
        try await Snapshot.save("projects-empty", size: CGSize(width: 900, height: 560),
                                MainView().environment(app).environment(app.workspace).environment(app.scheduler))
    }

    @Test func addProjectSheet() async throws {
        let ws = try workspace()
        defer { ws.store.signOut() }
        try await Snapshot.save("projects-sheet", wait: .seconds(1.5),
                                AddProjectSheet(client: ws.client()!, excluded: []) { _ in })
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct MRSnapshotTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-snap-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    static func mr(_ iid: Int, _ title: String, _ branch: String) -> MergeRequest {
        MergeRequest(projectID: 1, iid: iid, title: title, author: "eugene", sourceBranch: branch, targetBranch: "main",
                     webURL: URL(string: "https://x/mr/\(iid)")!, sha: "abc", draft: false, labels: [])
    }

    static func stage(_ kind: StageKind, _ state: StageState, _ caption: Stage.Caption = .none, _ detail: String = "", _ duration: Double? = nil, log: [LogLine] = []) -> Stage {
        Stage(kind: kind, state: state, caption: caption, detail: detail, startedAt: Date(), duration: duration, log: log)
    }

    static func fixtures() -> ([MergeRequest], [String: MRRun]) {
        let mrs = [mr(101, "Кеширование ответов API", "feature/api-cache"), mr(104, "Новый формат экспорта CSV", "feature/csv-export"),
                   mr(105, "Убрать устаревший эндпоинт", "chore/drop-v1-endpoint"), mr(103, "Обновить зависимости", "chore/update-deps"),
                   mr(102, "Исправить часовой пояс в отчётах", "fix/report-timezone"), mr(106, "Ограничить частоту запросов", "feature/rate-limit")]
        var runs: [String: MRRun] = [:]
        var live = MRRun()
        live.status = .running(.test, attempt: 1)
        live.stages = [stage(.rebase, .done, .onto, "origin/main", 1.3, log: [LogLine(text: "$ git fetch origin main", kind: .command), LogLine(text: "$ git rebase origin/main", kind: .command), LogLine(text: "Successfully rebased and updated refs/heads/feature/api-cache.", kind: .ok)]),
                       stage(.setup, .done, .command, "./scripts/setup.sh", 1.7),
                       stage(.test, .running, .command, "make test", log: [LogLine(text: "$ make test", kind: .command), LogLine(text: "running 128 tests…", kind: .output)]),
                       stage(.push, .pending), stage(.ci, .pending)]
        runs[mrs[0].id] = live
        var tests = MRRun()
        tests.status = .testsFailed
        tests.stages = [stage(.rebase, .done, .onto, "origin/main", 1.3), stage(.setup, .done, .command, "./scripts/setup.sh", 1.7),
                        stage(.test, .failed, .command, "make test", 2.8, log: [LogLine(text: "$ make test", kind: .command), LogLine(text: "FAIL export/csv_test: expected header \"id;name\", got \"id,name\"", kind: .output), LogLine(text: "make: *** [test] Error 1", kind: .error), LogLine(text: "notPushed", kind: .note)]),
                        stage(.push, .pending), stage(.ci, .pending)]
        runs[mrs[1].id] = tests
        var ci = MRRun()
        ci.status = .ciFailed(job: "lint")
        ci.pipelineID = 7
        ci.stages = [stage(.rebase, .done, .onto, "origin/main", 1.3), stage(.setup, .done, .command, "./scripts/setup.sh", 1.7), stage(.test, .done, .command, "make test", 2.8),
                     stage(.push, .done, .command, "git push --force-with-lease", 1.0), stage(.ci, .failed, .ciFailed, "lint", 3.6, log: [LogLine(text: "pipeline #7", kind: .output), LogLine(text: "lint: failed", kind: .error)])]
        runs[mrs[2].id] = ci
        var conflict = MRRun()
        conflict.status = .conflict(files: ["package.json", "src/config.ts"])
        conflict.stages = [stage(.rebase, .failed, .conflictFiles, "2", 0.9, log: [LogLine(text: "$ git rebase origin/main", kind: .command), LogLine(text: "CONFLICT (content): Merge conflict in package.json", kind: .output), LogLine(text: "$ git rebase --abort", kind: .command), LogLine(text: "abort", kind: .note)]),
                           stage(.setup, .pending), stage(.test, .pending), stage(.push, .pending), stage(.ci, .pending)]
        runs[mrs[3].id] = conflict
        var fresh = MRRun()
        fresh.status = .upToDate(pushed: false)
        fresh.stages = [stage(.rebase, .skipped, .notNeeded), stage(.setup, .skipped), stage(.test, .skipped), stage(.push, .skipped), stage(.ci, .done, .ciPassed, "", 4.2)]
        runs[mrs[4].id] = fresh
        var behind = MRRun()
        behind.status = .behind(commits: 3)
        behind.stages[0].caption = .onto
        behind.stages[0].detail = "origin/main"
        runs[mrs[5].id] = behind
        return (mrs, runs)
    }

    @Test func mergeRequests() async throws {
        let store = Store(directory: dir, keychain: keychain)
        let server = MockURLProtocol.server { _ in (404, Data()) }
        try store.signIn(Account(server: server, username: "me", name: "Me"), token: "t")
        defer { store.signOut() }
        let project = Project(id: 1, name: "project-main", path: "group/project-main", webURL: URL(string: "https://x")!,
                              cloneURL: URL(string: "https://x.git")!, defaultBranch: "main", targetBranch: "main", setup: "./scripts/setup.sh", test: "make test")
        store.projects = [project]
        let (mrs, runs) = Self.fixtures()
        store.saveMergeRequests([1: mrs])
        store.saveRuns(runs)
        let workspace = Workspace(store: store, configuration: { MockURLProtocol.configuration() })
        let scheduler = Scheduler(workspace: workspace)
        for (index, mr) in mrs.enumerated() {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] where index < 4 || appearance == .aqua {
                let view = MRDetailHost(project: project, selection: mr.id)
                    .environment(workspace).environment(scheduler)
                try await Snapshot.save("mr-\(mr.iid)-\(appearance == .aqua ? "light" : "dark")", size: CGSize(width: 1000, height: 600), appearance: appearance, view)
            }
        }
    }
}

private struct MRDetailHost: View {
    let project: Project
    @State var selection: String?
    var body: some View {
        ProjectDetail(project: project, selection: $selection)
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct SettingsSnapshotTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-snap-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    @Test func tabs() async throws {
        let store = Store(directory: dir, keychain: keychain)
        let server = MockURLProtocol.server { _ in (200, json(#"{"id": 1, "username": "eugene", "name": "E", "avatar_url": null}"#)) }
        try store.signIn(Account(server: server, username: "eugene", name: "Eugene", tokenExpiresAt: Date().addingTimeInterval(86400 * 90)), token: "t")
        defer { store.signOut() }
        let app = AppModel(store: store)
        let size = CGSize(width: 540, height: 640)
        try await Snapshot.save("settings-general", size: size, GeneralSettings().environment(app))
        try await Snapshot.save("settings-claude", size: size, wait: .seconds(3), ClaudeSettingsView().environment(app))
        try await Snapshot.save("settings-notifications", size: size, NotificationSettingsView().environment(app))
        try await Snapshot.save("settings-account", size: size, wait: .seconds(1.5), AccountSettings().environment(app))
        store.settings.scope = .all
        store.settings.claude.push = .auto
        try await Snapshot.save("settings-general-dark", size: size, appearance: .darkAqua, GeneralSettings().environment(app))
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct ProjectSettingsSnapshotTests {
    @Test func sheet() async throws {
        let view = ProjectSettingsSheet(project: PipelineTests.project, client: nil, claudeSettings: ClaudeSettings()) { _ in }
        try await Snapshot.save("project-settings", view)
        try await Snapshot.save("project-settings-dark", appearance: .darkAqua, view)
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1"))
struct FixSnapshotTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-snap-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    static func testsFix(_ phase: ClaudeFix.Phase) -> ClaudeFix {
        var fix = ClaudeFix(kind: .tests, phase: phase, maxAttempts: 2, stages: ClaudeFix.stageKinds(for: .tests).map { Stage(kind: $0) },
                            worktree: "/tmp/x", baseSHA: "abc")
        fix.summary = "Тест ждёт «;», экспорт писал «,». Разделитель теперь из options.delimiter, по умолчанию «;»."
        fix.commitMessage = "fix(export): use options.delimiter in CSV export"
        fix.sessionID = "s"
        fix[.claude] = Stage(kind: .claude, state: phase == .fixing ? .running : phase == .gaveUp ? .failed : .done,
                             caption: phase == .fixing ? .claudeAttempt : phase == .gaveUp ? .claudeFailed : .claudeChanged,
                             detail: phase == .fixing ? "1/2" : phase == .gaveUp ? "2" : "1/1/1", duration: 38.4,
                             log: [LogLine(text: "Смотрю, какой тест упал.", kind: .claude), LogLine(text: "Read  test/export/csv_test.ts", kind: .tool),
                                   LogLine(text: "Edit  src/export/csv.ts  (+1 −1)", kind: .tool), LogLine(text: "Bash  make test", kind: .tool),
                                   LogLine(text: "test result: ok. 128 passed", kind: .ok)])
        fix[.retest] = Stage(kind: .retest, state: [.ready, .pushed].contains(phase) ? .done : .pending, caption: .afterFix, detail: "make test", duration: 2.8)
        fix[.push] = Stage(kind: .push, state: phase == .pushed ? .done : .pending, caption: .command, detail: "git push --force-with-lease", duration: 1)
        fix[.ci] = Stage(kind: .ci, state: phase == .pushed ? .done : .pending, caption: phase == .pushed ? .ciPassed : .pipeline, duration: 3.6)
        fix.files = DiffParser.parse("""
        diff --git a/src/export/csv.ts b/src/export/csv.ts
        --- a/src/export/csv.ts
        +++ b/src/export/csv.ts
        @@ -10,3 +10,3 @@ export function toCsv(rows, options) {
           const header = columns.join(sep)
        -  const sep = ","
        +  const sep = options.delimiter ?? ";"
           return lines
        """)
        return fix
    }

    static func conflictFix() -> ClaudeFix {
        var fix = ClaudeFix(kind: .conflict, phase: .ready, maxAttempts: 2, stages: ClaudeFix.stageKinds(for: .conflict).map { Stage(kind: $0, state: .done) },
                            worktree: "/tmp/x", baseSHA: "abc")
        fix.summary = "Собрано из строк main и ветки. В одном месте свой код, стоит проверить."
        let conflicted = "{\n  \"deps\": {\n<<<<<<< HEAD\n    \"zod\": \"3.23.0\"\n=======\n    \"zod\": \"3.22.0\",\n    \"date-fns\": \"3.0.0\"\n>>>>>>> c\n  }\n}\n"
        let own = ConflictAnalysis.analyze(conflicted: conflicted, resolved: "{\n  \"deps\": {\n    \"zod\": \"^3.23.0\",\n    \"date-fns\": \"3.0.0\"\n  }\n}\n") ?? []
        let both = ConflictAnalysis.analyze(conflicted: conflicted, resolved: "{\n  \"deps\": {\n    \"zod\": \"3.23.0\",\n    \"date-fns\": \"3.0.0\"\n  }\n}\n") ?? []
        fix.files = [FixFile(path: "src/config.ts", kind: .conflict, conflicts: own, note: "Совместил оба импорта, версию взял новую."),
                     FixFile(path: "package.json", kind: .conflict, conflicts: both),
                     FixFile(path: "package-lock.json", kind: .lock, conflicts: Array(repeating: ResolvedConflict(startLine: 1, endLine: 1, source: .both, lines: [], dropped: []), count: 8))]
        fix.ownCode = true
        return fix
    }

    @Test func banners() async throws {
        let store = Store(directory: dir, keychain: keychain)
        try store.signIn(Account(server: MockURLProtocol.server { _ in (404, Data()) }, username: "me", name: "Me"), token: "t")
        defer { store.signOut() }
        let project = PipelineTests.project
        store.projects = [project]
        var mrs: [MergeRequest] = []
        var runs: [String: MRRun] = [:]
        for (i, phase) in [ClaudeFix.Phase.fixing, .ready, .pushed, .gaveUp].enumerated() {
            var mr = PipelineTests.mr
            mr.iid = 200 + i
            mr.title = "Новый формат экспорта CSV \(phase.rawValue)"
            mrs.append(mr)
            var run = MRSnapshotTests.fixtures().1.values.first { $0.status == .testsFailed }!
            run.fix = Self.testsFix(phase)
            if phase == .pushed { run.status = .upToDate(pushed: true) }
            runs[mr.id] = run
        }
        store.saveMergeRequests([project.id: mrs])
        store.saveRuns(runs)
        let workspace = Workspace(store: store)
        workspace.claude = ClaudeCLI.Check(path: "/x", status: .ready)
        let scheduler = Scheduler(workspace: workspace)
        for mr in mrs {
            try await Snapshot.save("fix-\(mr.iid)", size: CGSize(width: 1000, height: 640),
                                    FixHost(project: project, selection: mr.id).environment(workspace).environment(scheduler))
        }
        try await Snapshot.save("fix-sheet-tests", FixReviewSheet(mr: mrs[1], fix: Self.testsFix(.ready)).environment(workspace))
        try await Snapshot.save("fix-sheet-conflict", FixReviewSheet(mr: mrs[1], fix: Self.conflictFix()).environment(workspace))
        try await Snapshot.save("fix-sheet-conflict-dark", appearance: .darkAqua, FixReviewSheet(mr: mrs[1], fix: Self.conflictFix()).environment(workspace))
    }
}

private struct FixHost: View {
    let project: Project
    @State var selection: String?
    var body: some View { ProjectDetail(project: project, selection: $selection) }
}
