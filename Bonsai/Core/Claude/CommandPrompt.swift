// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct CommandPrompt: Sendable {
    var pick: Bool
    var branch: String
    var setup: String
    var test: String
    var failureLog = ""
    var rules: String
    var projectRules: String
    var environment: [String] = []
    var language: String

    static let schema =
        #"{"type":"object","properties":{"summary":{"type":"string"},"setup":{"type":"string"},"test":{"type":"string"}},"required":["summary","setup","test"]}"#

    static let allowedTools = ["Read", "Glob", "Grep", "Bash"]

    var text: String {
        var parts = ["You are setting up the commands Bonsai uses to check merge requests of this repository."]
        if pick {
            parts.append(
                """
                The project has no commands yet. Find out how this repository prepares its environment and runs its tests: \
                look at the Makefile, the CI configuration, docker-compose files, package manifests and scripts.
                """)
        } else {
            parts.append(
                """
                These commands fail on a clean checkout of `\(branch)`. \
                The branch itself is not known to be broken, so look for the problem in the commands or the local environment.
                Setup:
                ```
                \(setup)
                ```
                Tests:
                ```
                \(test)
                ```
                Last lines of the output:
                ```
                \(FixPrompt.tail(failureLog))
                ```
                """)
        }
        parts.append("Rules:\n" + rules.trimmingCharacters(in: .whitespacesAndNewlines))
        let project = projectRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty { parts.append("Project rules:\n" + project) }
        if let section = FixPrompt.environmentSection(environment) { parts.append(section) }
        parts.append(
            """
            Change only the commands. Do not edit, create or delete files in the repository: \
            anything the tests need must be created by the setup commands. Do not commit, push, checkout or stash.
            Run the commands to make sure they work on a clean checkout of `\(branch)`.
            When done, return `setup`: the shell commands to run before the tests, one per line, or an empty string. \
            Return `test`: the command that runs the tests. \
            Return `summary`: one or two sentences, at most 160 characters, in \(language), \
            saying what the tests need and what you \(pick ? "chose" : "changed").
            """)
        return parts.joined(separator: "\n\n")
    }

    func retry(output: String) -> String {
        """
        Bonsai ran your commands on a clean checkout and they failed:
        ```
        \(FixPrompt.tail(output))
        ```
        Fix them under the same rules and return the same fields.
        """
    }
}
