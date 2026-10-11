import Foundation
import Testing

@testable import Bonsai

struct GitLabProjectsTests {
    @Test func searchSendsMembershipAndTerm() async throws {
        let server = MockURLProtocol.server { _ in
            (
                200,
                json(
                    #"[{"id": 5, "name": "app", "path_with_namespace": "g/app", "web_url": "https://x/g/app", "http_url_to_repo": "https://x/g/app.git", "default_branch": "main"}]"#
                )
            )
        }
        let client = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        let found = try await client.projects(search: " app ")
        #expect(found.map(\.path) == ["g/app"])
        let url = try #require(MockURLProtocol.recorded(server).first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "membership", value: "true")))
        #expect(items.contains(URLQueryItem(name: "search", value: "app")))
    }

    @Test func branchesDefaultFirst() async throws {
        let server = MockURLProtocol.server { _ in
            (200, json(#"[{"name": "develop", "default": false}, {"name": "main", "default": true}]"#))
        }
        let client = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        #expect(try await client.branches(project: 5).map(\.name) == ["main", "develop"])
    }

    static func branchPage(_ request: URLRequest, total: Int, defaultAt: Int?) -> (Int, Data) {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = Int(items.first { $0.name == "page" }?.value ?? "1")!
        let size = GitLabClient.branchPageSize
        let names = (0..<total).map { $0 == defaultAt ? "master" : String(format: "BPDF-%04d", $0) }
        let slice = names.dropFirst((page - 1) * size).prefix(size)
        let entries = slice.map { #"{"name": "\#($0)", "default": \#($0 == "master")}"# }
        return (200, json("[" + entries.joined(separator: ",") + "]"))
    }

    @Test func branchesReadAllPages() async throws {
        let server = MockURLProtocol.server { Self.branchPage($0, total: 250, defaultAt: 249) }
        let client = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        let names = try await client.branches(project: 5, defaultBranch: "master").map(\.name)
        #expect(names.count == 250)
        #expect(names.first == "master")
        #expect(MockURLProtocol.recorded(server).count == 3)
    }

    @Test func branchesStopAtPageLimitAndFetchDefaultSeparately() async throws {
        let total = GitLabClient.branchPageSize * (GitLabClient.branchPageLimit + 2)
        let server = MockURLProtocol.server { request in
            if request.url!.path().hasSuffix("/repository/branches/master") {
                return (200, json(#"{"name": "master", "default": true}"#))
            }
            return Self.branchPage(request, total: total, defaultAt: total - 1)
        }
        let client = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        let names = try await client.branches(project: 5, defaultBranch: "master").map(\.name)
        #expect(names.first == "master")
        #expect(names.count == GitLabClient.branchPageSize * GitLabClient.branchPageLimit + 1)
        #expect(MockURLProtocol.recorded(server).count == GitLabClient.branchPageLimit + 1)
    }

    @Test func fileRawEncodesPathAnd404IsNil() async throws {
        let server = MockURLProtocol.server { request in
            request.url!.absoluteString.contains("scripts%2Fsetup.sh") ? (200, Data("#!/bin/sh".utf8)) : (404, Data())
        }
        let client = GitLabClient(server: server, token: "t", configuration: MockURLProtocol.configuration())
        #expect(try await client.file(project: 5, path: "scripts/setup.sh", ref: "main") == "#!/bin/sh")
        #expect(try await client.file(project: 5, path: "Makefile", ref: "main") == nil)
    }
}
