import Foundation

struct FixPrompt: Sendable {
    var kind: ClaudeFix.Kind
    var branch: String
    var base: String
    var setup: String
    var test: String
    var rules: String
    var projectRules: String
    var failureLog: String = ""
    var job: String?
    var conflictFiles: [String] = []
    var language: String

    static let logTailLines = 150

    static let schema = #"{"type":"object","properties":{"summary":{"type":"string"},"commit":{"type":"string"},"files":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"note":{"type":"string"}},"required":["path","note"]}}},"required":["summary","commit"]}"#

    static let lockFiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "Gemfile.lock",
                                          "go.sum", "mix.lock", "poetry.lock", "composer.lock", "Podfile.lock", "Package.resolved", "uv.lock"]

    static func isLockFile(_ path: String) -> Bool {
        lockFiles.contains((path as NSString).lastPathComponent)
    }

    var allowedTools: [String] {
        var tools = ["Read", "Edit", "Write", "Glob", "Grep"]
        for command in (setup + "\n" + test).split(separator: "\n") {
            let line = command.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { tools.append("Bash(\(line))") }
        }
        if kind == .conflict {
            tools += ["Bash(git add *)", "Bash(npm install *)", "Bash(npm install)", "Bash(yarn install *)", "Bash(yarn install)",
                      "Bash(pnpm install *)", "Bash(pnpm install)", "Bash(cargo generate-lockfile)", "Bash(cargo update *)",
                      "Bash(bundle install)", "Bash(go mod tidy)", "Bash(mix deps.get)", "Bash(swift package resolve)"]
        }
        return tools
    }

    var text: String {
        var parts: [String] = []
        parts.append("You are fixing a failure for Bonsai, an app that keeps merge requests rebased and green.")
        switch kind {
        case .tests:
            parts.append("""
            Branch `\(branch)` was rebased onto `\(base)` and the test command failed:
            ```
            \(test)
            ```
            Last lines of the output:
            ```
            \(Self.tail(failureLog))
            ```
            """)
        case .ci:
            parts.append("""
            CI job `\(job ?? "pipeline")` failed for branch `\(branch)`. Last lines of the job log:
            ```
            \(Self.tail(failureLog))
            ```
            """)
        case .conflict:
            parts.append("""
            Rebasing branch `\(branch)` onto `\(base)` stopped with conflicts in:
            \(conflictFiles.map { "- \($0)" }.joined(separator: "\n"))
            You are inside the unfinished rebase. Resolve the conflict markers in these files so both sides keep working. \
            Prefer lines from either side over writing new code. Regenerate lock files with the package manager instead of merging them by hand. \
            Stage each resolved file with `git add`. Do not run `git rebase --continue` or `git rebase --abort`.
            """)
        }
        parts.append("Rules:\n" + rules.trimmingCharacters(in: .whitespacesAndNewlines))
        let project = projectRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty { parts.append("Project rules:\n" + project) }
        parts.append("""
        Do not commit, push, reset, checkout, stash or rebase: Bonsai handles git.
        Check your fix with the project's test command:
        ```
        \(test)
        ```
        When done, return `summary`: one or two sentences, at most 160 characters, in \(language), saying what was wrong and what you changed. \
        Return `commit`: \(kind == .conflict ? "an empty string (the resolution goes into the rebase)" : "a commit message for your change that follows the rules"). \
        \(kind == .conflict ? "Return `files`: for each resolved file, its path and a short note in \(language) on how you resolved it." : "")
        """)
        return parts.joined(separator: "\n\n")
    }

    func retry(testOutput: String) -> String {
        """
        The tests still fail after your change:
        ```
        \(Self.tail(testOutput))
        ```
        Fix it under the same rules and return the same fields.
        """
    }

    static func tail(_ log: String) -> String {
        let clean = log.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return clean.split(separator: "\n", omittingEmptySubsequences: false).suffix(logTailLines).joined(separator: "\n")
    }

    static func languageName(_ code: String) -> String {
        code.hasPrefix("ru") ? "Russian" : "English"
    }
}
