// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct CommandPromptTests {
    @Test func claudeCanReadAndRunButNotEdit() {
        #expect(CommandPrompt.allowedTools == ["Read", "Glob", "Grep", "Bash"])
        let schema = try? JSONSerialization.jsonObject(with: Data(CommandPrompt.schema.utf8)) as? [String: Any]
        #expect(schema?["required"] as? [String] == ["summary", "setup", "test"])
    }

    @Test func fixPromptCarriesCommandsFailureAndRules() {
        let prompt = CommandPrompt(
            pick: false, branch: "main", setup: "./scripts/setup.sh", test: "make test",
            failureLog: "Error: connect ECONNREFUSED 127.0.0.1:5432", rules: "Minimal.", projectRules: "No migrations/",
            language: "Russian")
        #expect(prompt.text.contains("./scripts/setup.sh"))
        #expect(prompt.text.contains("ECONNREFUSED"))
        #expect(prompt.text.contains("Project rules:\nNo migrations/"))
        #expect(prompt.text.contains("in Russian"))
        #expect(!prompt.text.contains("no commands yet"))
        #expect(prompt.retry(output: "FAIL x").contains("FAIL x"))
    }
}
