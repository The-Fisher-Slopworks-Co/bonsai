import Foundation
import Testing
@testable import Bonsai

struct ConflictAnalysisTests {
    let conflicted = """
    {
      "name": "app",
      "dependencies": {
    <<<<<<< HEAD
        "zod": "3.23.0"
    =======
        "zod": "3.22.0",
        "date-fns": "3.0.0"
    >>>>>>> 1a2b3c4 (Add date-fns)
      }
    }

    """

    @Test func bothSidesPicked() throws {
        let resolved = """
        {
          "name": "app",
          "dependencies": {
            "zod": "3.23.0",
            "date-fns": "3.0.0"
          }
        }

        """
        let result = try #require(ConflictAnalysis.analyze(conflicted: conflicted, resolved: resolved))
        #expect(result.count == 1)
        let conflict = result[0]
        #expect(conflict.source == .both)
        #expect(conflict.startLine == 4)
        #expect(conflict.endLine == 5)
        #expect(conflict.lines.filter { $0.origin == .main }.map(\.text) == [#"    "zod": "3.23.0","#])
        #expect(conflict.lines.filter { $0.origin == .branch }.map(\.text) == [#"    "date-fns": "3.0.0""#])
        #expect(conflict.dropped.map(\.text) == [#"    "zod": "3.22.0","#])
        #expect(conflict.lines.first?.origin == .context)
    }

    @Test func ownCodeDetected() throws {
        let resolved = """
        {
          "name": "app",
          "dependencies": {
            "zod": "^3.23.0",
            "date-fns": "3.0.0"
          }
        }

        """
        let result = try #require(ConflictAnalysis.analyze(conflicted: conflicted, resolved: resolved))
        #expect(result[0].source == .own)
        #expect(result[0].lines.contains { $0.origin == .own && $0.text.contains("^3.23.0") })
    }

    @Test func onlyMainSide() throws {
        let resolved = "{\n  \"name\": \"app\",\n  \"dependencies\": {\n    \"zod\": \"3.23.0\"\n  }\n}\n"
        let result = try #require(ConflictAnalysis.analyze(conflicted: conflicted, resolved: resolved))
        #expect(result[0].source == .main)
        #expect(result[0].dropped.count == 2)
    }

    @Test func multipleConflictsAndDiff3() throws {
        let text = "a\n<<<<<<< HEAD\nm1\n||||||| base\nb1\n=======\nx1\n>>>>>>> c\nmid\n<<<<<<< HEAD\nm2\n=======\nx2\n>>>>>>> c\nend\n"
        let resolved = "a\nm1\nmid\nx2\nend\n"
        let result = try #require(ConflictAnalysis.analyze(conflicted: text, resolved: resolved))
        #expect(result.map(\.source) == [.main, .branch])
        #expect(result.map(\.startLine) == [2, 4])
    }

    @Test func unalignedResolutionIsNil() {
        #expect(ConflictAnalysis.analyze(conflicted: conflicted, resolved: "totally different\n") == nil)
        #expect(ConflictAnalysis.analyze(conflicted: "no markers\n", resolved: "no markers\n") == nil)
    }
}

struct DiffParserTests {
    @Test func parsesFilesHunksAndCounts() {
        let diff = """
        diff --git a/src/export/csv.ts b/src/export/csv.ts
        index 1..2 100644
        --- a/src/export/csv.ts
        +++ b/src/export/csv.ts
        @@ -10,3 +10,3 @@ export function toCsv(rows, options) {
           const header = columns.join(sep)
        -  const sep = ","
        +  const sep = options.delimiter ?? ";"
           return lines
        diff --git a/test/csv_test.ts b/test/csv_test.ts
        new file mode 100644
        --- /dev/null
        +++ b/test/csv_test.ts
        @@ -0,0 +1 @@
        +it("works")
        """
        let files = DiffParser.parse(diff)
        #expect(files.map(\.path) == ["src/export/csv.ts", "test/csv_test.ts"])
        #expect(files[0].added == 1)
        #expect(files[0].removed == 1)
        #expect(files[0].hunks.first?.newStart == 10)
        #expect(files[0].hunks.first?.lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(files[1].added == 1)
    }

    @Test(arguments: [("test/export/csv_test.ts", true), ("src/a.spec.ts", true), ("pkg/x_test.go", true), ("__tests__/a.js", true),
                      ("BonsaiTests/StoreTests.swift", true), ("src/export/csv.ts", false), ("README.md", false)])
    func testPaths(path: String, expected: Bool) {
        #expect(DiffParser.isTestPath(path) == expected)
    }
}
