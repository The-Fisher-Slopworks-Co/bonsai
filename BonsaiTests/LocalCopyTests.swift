// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct LocalCopyTests {
    static var project: Project {
        var project = PipelineTests.project
        project.localCopy = "/tmp/checkout"
        project.copied = "node_modules\nconfig/local.env"
        return project
    }

    func localCopy(_ root: URL) throws -> URL {
        let local = root.appendingPathComponent("local")
        for (path, text) in [
            ("node_modules/left-pad/index.js", "module.exports = 1\n"), ("config/local.env", "PORT=4000\n"),
            ("README.md", "local readme\n"),
        ] {
            let url = local.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return local
    }

    func read(_ dir: URL, _ path: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func oldProjectsDecodeWithoutLocalCopy() throws {
        let json = #"""
            [{"id": 1, "name": "app", "path": "g/app", "webURL": "https://x/g", "cloneURL": "https://x/g.git",
              "defaultBranch": "main", "targetBranch": "main", "setup": "", "test": "make test"}]
            """#
        let project = try #require(try JSONDecoder().decode([Project].self, from: Data(json.utf8)).first)
        #expect(project.localCopy == "")
        #expect(project.copied == "")
        #expect(project.rules == "")
        #expect(project.claude == .inherit)
        #expect(!project.copiesLocally)
        let again = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(Self.project))
        #expect(again == Self.project)
    }

    @Test func copiesFilesAndDirsOutsideGit() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        try repo.write("config/local.env", "PORT=3000\n")
        try await repo.commit("tracked config")
        try await repo.sh("git push -q origin main", in: repo.seed)
        try await repo.sh("git checkout -q -b next && echo 'PORT=5000' > config/local.env", in: repo.seed)
        try await repo.commit("next config")
        try await repo.sh("git push -q origin next && git checkout -q main", in: repo.seed)
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let local = try localCopy(repo.root)
        try repo.write("node_modules/stale.js", "old\n", in: clone.directory)

        let lines = LogBox()
        let paths = ["node_modules", "config/local.env"]
        try await clone.copy(paths, from: local.path, log: { lines.add($0) })
        try await clone.copy(paths, from: local.path, log: { _ in })

        #expect(read(clone.directory, "node_modules/left-pad/index.js") == "module.exports = 1\n")
        #expect(read(clone.directory, "node_modules/stale.js") == nil)
        #expect(read(clone.directory, "config/local.env") == "PORT=4000\n")
        #expect(lines.all.first == LogLine(text: "$ cp -c -R \(local.path)/node_modules node_modules", kind: .command))
        #expect(try await clone.isClean)
        let exclude = try #require(read(clone.directory, ".git/info/exclude"))
        #expect(exclude.components(separatedBy: "\n").filter { $0 == "/node_modules" }.count == 1)

        try await clone.checked(["add", "-A"])
        #expect(try await clone.checked(["diff", "--cached", "--name-only"]).isEmpty)

        let effects = LivePipelineEffects(
            git: clone, gitlab: GitLabClient(server: URL(string: "http://localhost")!, token: ""), projectID: 1)
        try await effects.detach("origin/next", log: { _ in })
        #expect(read(clone.directory, "config/local.env") == "PORT=5000\n")
        try await clone.copy(paths, from: local.path, log: { _ in })
        try await effects.checkout("main", log: { _ in })
        #expect(read(clone.directory, "config/local.env") == "PORT=3000\n")
        #expect(read(clone.directory, "node_modules/left-pad/index.js") != nil)
        #expect(try await clone.isClean)
    }

    @Test func worktreeExcludesGoToTheCommonDir() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let tree = repo.root.appendingPathComponent("fixes/7")
        try await clone.checked(["worktree", "add", "--detach", tree.path, "origin/main"])
        let worktree = GitRunner(directory: tree)
        try await worktree.copy(["node_modules"], from: try localCopy(repo.root).path, log: { _ in })
        #expect(read(tree, "node_modules/left-pad/index.js") != nil)
        #expect(read(clone.directory, ".git/info/exclude")?.contains("/node_modules\n") == true)
        #expect(try await worktree.isClean)
    }

    @Test func missingPathOrFolderFails() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let local = try localCopy(repo.root)
        await #expect(throws: LocalCopyError(path: "deps")) {
            try await clone.copy(["node_modules", "deps"], from: local.path, log: { _ in })
        }
        #expect(read(clone.directory, "node_modules/left-pad/index.js") == nil)
        await #expect(throws: LocalCopyError(path: "node_modules")) {
            try await clone.copy(["node_modules"], from: repo.root.appendingPathComponent("gone").path, log: { _ in })
        }
    }

    @Test func refusesPathsOutsideTheCheckout() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let outside = repo.root.appendingPathComponent("outside")
        try repo.write("secret", "s\n", in: outside)
        try await repo.sh("ln -s \(outside.path) linked && git add linked", in: repo.seed)
        try await repo.commit("link")
        try await repo.sh("git push -q origin main", in: repo.seed)
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let local = try localCopy(repo.root)
        try repo.write("linked/secret", "local\n", in: local)
        try repo.write(".git/config", "x\n", in: local)
        try await repo.sh("ln -s \(outside.path) \(local.path)/escape", in: repo.root)
        for path in [".", "./", "node_modules/..", ".git", "./.git/config", "linked/secret", "escape/secret"] {
            await #expect(throws: LocalCopyError(path: path, outside: true), "\(path)") {
                try await clone.copy(["node_modules", path], from: local.path, log: { _ in })
            }
        }
        #expect(read(clone.directory, "node_modules/left-pad/index.js") == nil)
        #expect(read(outside, "secret") == "s\n")
        #expect(try await clone.isClean)
        #expect(LocalCopyError(path: ".", outside: true).localizedDescription == "cp: .: outside the checkout")
    }

    @Test func excludesOnlyWhatTheCopyAddsToTrackedDirs() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        try repo.write("config/app.env", "A=1\n")
        try await repo.commit("config")
        try await repo.sh("git push -q origin main", in: repo.seed)
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let exclude = clone.directory.appendingPathComponent(".git/info/exclude")
        try "# mine\n/own\n".write(to: exclude, atomically: true, encoding: .utf8)
        let local = try localCopy(repo.root)
        try repo.write("config/app.env", "A=2\n", in: local)
        try repo.write("config/cache/x", "x\n", in: local)

        try await clone.copy(["node_modules", "config"], from: local.path, log: { _ in })
        #expect(read(clone.directory, "config/app.env") == "A=2\n")
        #expect(try await clone.isClean)
        #expect(
            read(clone.directory, ".git/info/exclude")
                == "# mine\n/own\n# bonsai local copy\n/node_modules\n/config/cache/\n/config/local.env\n"
                + "# end bonsai local copy\n")
        try repo.write("config/new.env", "B=1\n", in: clone.directory)
        #expect(try await clone.checked(["status", "--porcelain"]) == "?? config/new.env")

        try await clone.copy(["config/local.env"], from: local.path, log: { _ in })
        #expect(
            read(clone.directory, ".git/info/exclude")
                == "# mine\n/own\n# bonsai local copy\n/config/local.env\n# end bonsai local copy\n")
    }

    @Test func failsWhenTheOldCopyCannotBeRemoved() async throws {
        let repo = try await TempRepo()
        defer { repo.remove() }
        let clone = GitRunner(directory: repo.root.appendingPathComponent("clone"))
        try await clone.clone(URL(fileURLWithPath: repo.origin.path))
        let local = try localCopy(repo.root)
        let locked = clone.directory.appendingPathComponent("node_modules")
        try repo.write("node_modules/old.js", "old\n", in: clone.directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        await #expect(throws: (any Error).self) {
            try await clone.copy(["node_modules"], from: local.path, log: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: locked.appendingPathComponent("node_modules").path))
    }

    @Test func processRunnerFeedsInput() async throws {
        let result = try await ProcessRunner.run("/bin/cat", [], input: Data("a\0b".utf8))
        #expect(result.output == "a\0b")
    }

    @Test func fixStopsAsUnavailableOnMissingPath() async throws {
        let tests = FixPipelineTests()
        let f = try await tests.fixture(
            branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { try $0.write("CHANGELOG", "x\n") })
        defer { f.repo.remove() }
        var project = f.project
        project.localCopy = try localCopy(f.repo.root).path
        project.copied = "deps"
        let claude = FakeClaude { _, _ in
            Issue.record("claude ran")
            return ok("Fixed.", commit: "Fix add")
        }
        let worktree = f.repo.root.appendingPathComponent("fixes/g/app/7")
        let effects = LiveFixEffects(
            clone: f.clone, worktree: worktree,
            gitlab: GitLabClient(server: f.server, token: "t", configuration: MockURLProtocol.configuration()),
            projectID: 1, claudePath: "/usr/bin/true", runner: claude)
        let fixer = FixPipeline(mr: f.mr, project: project, effects: effects, rules: "Minimal.")
        let run = await fixer.fix(.tests, RunRecorder(tests.failedRun(.testsFailed)) { _ in })
        #expect(run.status == .unavailable)
        #expect(run.fix == nil)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func commandFixStopsAsUnavailableOnMissingPath() async {
        let effects = FakeEffects()
        effects.missingCopies = ["node_modules"]
        let start = MainCheck(sha: "base1", commands: MainCheck.Commands(setup: "", test: ""), pick: true)
        let prompt = CommandPrompt(
            pick: true, branch: "main", setup: "", test: "", rules: "Minimal.", projectRules: "", language: "English")
        let result = await MainPipeline(project: Self.project, effects: effects).fix(
            prompt, attempts: 1,
            claude: { _, _, _ in
                Issue.record("claude ran")
                return MainPipelineTests.answer(setup: "", test: "make test")
            }, Recorder(start) { _ in })
        #expect(result.phase == .unavailable)
        #expect(result.proposal?[.pick].log.last?.text == LocalCopyError(path: "node_modules").localizedDescription)
    }

    @Test func missingPathMessage() throws {
        let en = try L10nTests().bundle("en")
        let ru = try L10nTests().bundle("ru")
        #expect(localized("localCopy.missing", bundle: en, ["deps"]) == "“deps” isn’t in the local copy.")
        #expect(localized("localCopy.missing", bundle: ru, ["deps"]) == "В локальной копии нет «deps».")
    }

    @Test func mrPipelineCopiesBeforeSetup() async {
        let effects = FakeEffects()
        let (run, _) = await PipelineTests().execute(effects, project: Self.project)
        #expect(run.status == .upToDate(pushed: true))
        let copy = "copy node_modules,config/local.env from /tmp/checkout"
        let order = ["rebase origin/main", copy, "run ./scripts/setup.sh"].compactMap(effects.calls.firstIndex(of:))
        #expect(order.count == 3 && order == order.sorted())
    }

    @Test func mrPipelineFailsOnMissingPath() async {
        let effects = FakeEffects()
        effects.missingCopies = ["config/local.env"]
        let (run, _) = await PipelineTests().execute(effects, project: Self.project)
        let message = LocalCopyError(path: "config/local.env").localizedDescription
        #expect(run.status == .unavailable)
        #expect(run[.rebase].state == .failed)
        #expect(run[.rebase].log.last == LogLine(text: message, kind: .error))
        #expect(!effects.calls.contains { $0.hasPrefix("run ") || $0.hasPrefix("push") })
    }

    @Test func noCopyWithoutLocalCopy() async {
        var project = Self.project
        project.localCopy = ""
        let effects = FakeEffects()
        _ = await PipelineTests().execute(effects, project: project)
        #expect(!effects.calls.contains { $0.hasPrefix("copy") })
    }

    @Test func mainCheckCopiesAfterCheckout() async throws {
        let effects = FakeEffects()
        let result = try await MainPipelineTests().check(effects, project: Self.project)
        #expect(result.phase == .passed)
        #expect(
            Array(effects.calls.dropFirst()) == [
                "detach origin/main", "copy node_modules,config/local.env from /tmp/checkout", "run ./scripts/setup.sh",
                "run make test",
            ])
    }

    @Test func mainCheckMissingPathIsNotACommandFailure() async throws {
        let effects = FakeEffects()
        effects.missingCopies = ["node_modules"]
        let result = try await MainPipelineTests().check(effects, project: Self.project)
        #expect(result.phase == .unavailable)
        #expect(result[.checkout].state == .failed)
        #expect(result[.checkout].log.last?.text == LocalCopyError(path: "node_modules").localizedDescription)
        #expect(!effects.calls.contains { $0.hasPrefix("run ") })
    }

    @Test func commandFixVerifiesWithCopies() async {
        let effects = FakeEffects()
        let start = MainCheck(sha: "base1", commands: MainCheck.Commands(setup: "", test: ""), pick: true)
        let prompt = CommandPrompt(
            pick: true, branch: "main", setup: "", test: "", rules: "Minimal.", projectRules: "", language: "English")
        let result = await MainPipeline(project: Self.project, effects: effects).fix(
            prompt, attempts: 1,
            claude: { _, _, _ in MainPipelineTests.answer(setup: "", test: "make test") }, Recorder(start) { _ in })
        #expect(result.phase == .ready)
        #expect(
            effects.calls.suffix(3) == [
                "detach origin/main", "copy node_modules,config/local.env from /tmp/checkout", "run make test",
            ])
    }

    @Test func promptMentionsLocalCopyOnlyWhenSet() {
        var prompt = CommandPrompt(
            pick: true, branch: "main", setup: "", test: "", rules: "Minimal.", projectRules: "", language: "English")
        #expect(!prompt.text.contains("working checkout"))
        prompt.localCopy = "/tmp/checkout"
        prompt.copied = ["node_modules"]
        #expect(prompt.text.contains("working checkout of this repository on this machine at `/tmp/checkout`"))
        #expect(prompt.text.contains("never modify it"))
        #expect(prompt.text.contains("never write through them"))
        #expect(prompt.text.contains("before setup:\n- node_modules"))

        var fix = FixPrompt(
            kind: .tests, branch: "feature", base: "origin/main", setup: "", test: "make test", rules: "Minimal.",
            projectRules: "", language: "English")
        #expect(!fix.text.contains("working checkout"))
        fix.localCopy = "/tmp/checkout"
        #expect(fix.text.contains("at `/tmp/checkout`"))
        #expect(!fix.text.contains("before setup:"))
        #expect(Self.project.localCopyPath == "/tmp/checkout")
        var tilde = Self.project
        tilde.localCopy = "~/src/project"
        #expect(tilde.localCopyPath == NSHomeDirectory() + "/src/project")
    }

    @Test func runnerGivesClaudeTheLocalCopy() {
        var request = ClaudeRequest(
            executable: "claude", directory: URL(fileURLWithPath: "/tmp"), prompt: "p", allowedTools: ["Read"],
            schema: "{}")
        #expect(!LiveClaudeRunner().arguments(request).contains("--add-dir"))
        request.directories = ["/tmp/"]
        let args = LiveClaudeRunner().arguments(request)
        #expect(args.firstIndex(of: "--add-dir").map { args[$0 + 1] } == "/tmp/")
        let denied = args.firstIndex(of: "--disallowedTools").map { Array(args[($0 + 1)...]) }
        #expect(denied == ["Edit(//private/tmp/**)", "Edit(//tmp/**)"])
    }

    @Test func fixWorktreeGetsCopiesThatStayOutOfTheCommit() async throws {
        let tests = FixPipelineTests()
        let f = try await tests.fixture(
            branch: { try $0.write("add.sh", "echo $(($1 - $2))\n") }, main: { try $0.write("CHANGELOG", "x\n") })
        defer { f.repo.remove() }
        let local = try localCopy(f.repo.root)
        var project = f.project
        project.localCopy = local.path
        project.copied = "node_modules\nREADME.md"
        let claude = FakeClaude { request, _ in
            #expect(request.directories == [local.path])
            #expect(request.prompt.contains("at `\(local.path)`"))
            #expect(self.read(request.directory, "node_modules/left-pad/index.js") != nil)
            #expect(self.read(request.directory, "README.md") == "local readme\n")
            try "echo $(($1 + $2))\n".write(
                to: request.directory.appendingPathComponent("add.sh"), atomically: true, encoding: .utf8)
            return ok("Fixed.", commit: "Fix add")
        }
        let effects = LiveFixEffects(
            clone: f.clone, worktree: f.repo.root.appendingPathComponent("fixes/g/app/7"),
            gitlab: GitLabClient(server: f.server, token: "t", configuration: MockURLProtocol.configuration()),
            projectID: 1, claudePath: "/usr/bin/true", runner: claude, directories: [local.path])
        var config = FixPipeline.Config()
        config.ciPollInterval = 0.01
        let fixer = FixPipeline(mr: f.mr, project: project, effects: effects, rules: "Minimal.", config: config)
        let recorder = RunRecorder(tests.failedRun(.testsFailed)) { _ in }
        let run = await fixer.fix(.tests, recorder)
        #expect(run.fix?.phase == .ready)
        #expect(run.fix?.files.map(\.path) == ["add.sh"])
        try "changed\n".write(to: local.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let rechecked = await fixer.recheck(recorder)
        #expect(rechecked.fix?.phase == .ready)
        #expect(read(effects.worktree, "README.md") == "local readme\n")
        let pushed = await fixer.push(message: "Fix add", recorder)
        #expect(pushed.fix?.phase == .pushed)
        let files = try await f.repo.sh(
            "git --git-dir=\(f.repo.origin.path) show --name-only --format= feature", in: f.repo.root)
        #expect(files == "add.sh")
    }
}

@MainActor
struct LocalCopySettingsTests {
    @Test func copiedPathsMustStayInsideTheRepo() {
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        model.draft.localCopy = " ~/src/project \n"
        model.draft.copied = " node_modules \n\n config/local.env\n"
        #expect(model.canSave)
        let saved = model.saved()
        #expect(saved.localCopy == "~/src/project")
        #expect(saved.copied == "node_modules\nconfig/local.env")
        for bad in [
            "/etc/hosts", "../other", "deps/../../x", "~/x", ".", "./", "./.", ".git", "./.git/hooks", ".git/config",
        ] {
            model.draft.copied = "node_modules\n" + bad
            #expect(!model.canSave, "\(bad)")
        }
        model.draft.copied = "..cache"
        #expect(model.canSave)
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    func add(_ line: LogLine) { lock.withLock { lines.append(line) } }
    var all: [LogLine] { lock.withLock { lines } }
}
