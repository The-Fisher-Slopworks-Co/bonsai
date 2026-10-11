import Foundation
import Testing

@testable import Bonsai

struct FixPromptTests {
    func prompt(_ kind: ClaudeFix.Kind) -> FixPrompt {
        FixPrompt(
            kind: kind, branch: "feature/csv", base: "origin/main", setup: "npm ci", test: "make test",
            rules: "Только причина сбоя.", projectRules: "Не трогай migrations/",
            failureLog: (1...300).map { "line \($0)" }.joined(separator: "\n"),
            job: "lint", conflictFiles: ["package.json", "src/config.ts"], language: "Russian")
    }

    @Test func testsPromptCarriesRulesAndTailOfOutput() {
        let text = prompt(.tests).text
        #expect(text.contains("Только причина сбоя."))
        #expect(text.contains("Project rules:\nНе трогай migrations/"))
        #expect(text.contains("line 300"))
        #expect(!text.contains("line 150\n"))
        #expect(text.contains("in Russian"))
        #expect(text.contains("Do not commit"))
    }

    @Test func ciPromptNamesJob() {
        #expect(prompt(.ci).text.contains("CI job `lint` failed"))
    }

    @Test func conflictPromptListsFilesAndForbidsContinue() {
        let p = prompt(.conflict)
        #expect(p.text.contains("- package.json\n- src/config.ts"))
        #expect(p.text.contains("Do not run `git rebase --continue`"))
        #expect(p.allowedTools.contains("Bash(git add *)"))
        #expect(p.allowedTools.contains("Bash(npm install)"))
    }

    @Test func toolsAllowOnlyProjectCommands() {
        let tools = prompt(.tests).allowedTools
        #expect(tools.contains("Bash(npm ci)"))
        #expect(tools.contains("Bash(make test)"))
        #expect(!tools.contains("Bash(git add *)"))
        #expect(!tools.contains("Bash"))
    }

    @Test func emptyProjectRulesAreOmitted() {
        var p = prompt(.tests)
        p.projectRules = "  "
        #expect(!p.text.contains("Project rules"))
    }

    @Test func tailStripsColors() {
        #expect(FixPrompt.tail("\u{1B}[31mFAIL\u{1B}[0m") == "FAIL")
    }

    @Test func schemaIsValidJSON() throws {
        let object = try JSONSerialization.jsonObject(with: Data(FixPrompt.schema.utf8)) as? [String: Any]
        #expect((object?["required"] as? [String]) == ["summary", "commit"])
    }
}
