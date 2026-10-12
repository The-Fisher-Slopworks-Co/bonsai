// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

@MainActor
struct AddProjectModelTests {
    nonisolated static func projectJSON(_ id: Int, _ path: String) -> String {
        let name = path.split(separator: "/").last!
        return
            #"{"id": \#(id), "name": "\#(name)", "path_with_namespace": "\#(path)", "web_url": "https://x/\#(path)", "http_url_to_repo": "https://x/\#(path).git", "default_branch": "main"}"#
    }

    nonisolated static let handler: MockURLProtocol.Handler = { request in
        let url = request.url!
        let path = url.path()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let search = query.first { $0.name == "search" }?.value ?? ""
        if path.hasSuffix("/api/v4/projects") {
            let all = [(1, "g/project-main"), (2, "g/project-api"), (3, "g/project-docs")]
            let found = all.filter { search.isEmpty || $0.1.contains(search) }.map { projectJSON($0.0, $0.1) }
            return (200, json("[" + found.joined(separator: ",") + "]"))
        }
        if path.hasSuffix("/repository/branches") {
            return (200, json(#"[{"name": "develop", "default": false}, {"name": "main", "default": true}]"#))
        }
        return (404, Data())
    }

    func model(excluded: Set<Int> = []) -> AddProjectModel {
        let server = MockURLProtocol.server(Self.handler)
        let client = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        return AddProjectModel(client: client, excluded: excluded, debounce: .milliseconds(1))
    }

    @Test func commandsStartEmptyForClaudeToPick() async {
        let model = model()
        model.start()
        await model.settle()
        await model.settle()
        #expect(model.results.map(\.path) == ["g/project-main", "g/project-api", "g/project-docs"])
        #expect(model.selected?.path == "g/project-main")
        #expect(model.branches.map(\.name) == ["main", "develop"])
        #expect(model.branch == "main")
        #expect(model.setup.isEmpty)
        #expect(model.test.isEmpty)
        #expect(model.canAdd)
        let project = model.project()
        #expect(project?.targetBranch == "main")
        #expect(project?.test == "")
    }

    @Test func searchFiltersAndExcludesAdded() async {
        let model = model(excluded: [1])
        model.start()
        await model.settle()
        #expect(model.results.map(\.id) == [2, 3])
        model.query = "docs"
        await model.settle()
        await model.settle()
        #expect(model.results.map(\.id) == [3])
        #expect(model.selectedID == 3)
    }

    @Test func typedCommandsAreTrimmedAndResetWithTheProject() async {
        let model = model()
        model.start()
        await model.settle()
        await model.settle()
        model.setup = " npm ci \n"
        model.test = " npm test "
        #expect(model.project()?.setup == "npm ci")
        #expect(model.project()?.test == "npm test")
        model.selectedID = 2
        await model.settle()
        #expect(model.setup.isEmpty)
        #expect(model.test.isEmpty)
    }

    @Test func emptySearch() async {
        let model = model()
        model.query = "zzz"
        await model.settle()
        #expect(model.results.isEmpty)
        #expect(model.searched)
        #expect(model.selected == nil)
        #expect(!model.canAdd)
    }
}
