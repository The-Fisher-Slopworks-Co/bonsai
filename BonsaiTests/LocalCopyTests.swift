// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct LocalCopyTests {
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

    @Test func missingPathMessage() throws {
        let en = try L10nTests().bundle("en")
        let ru = try L10nTests().bundle("ru")
        #expect(localized("localCopy.missing", bundle: en, ["deps"]) == "“deps” isn’t in the local copy.")
        #expect(localized("localCopy.missing", bundle: ru, ["deps"]) == "В локальной копии нет «deps».")
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    func add(_ line: LogLine) { lock.withLock { lines.append(line) } }
    var all: [LogLine] { lock.withLock { lines } }
}
