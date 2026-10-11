import Foundation
@testable import Bonsai

enum LiveGitLab {
    static let server = URL(string: "http://localhost:8929")!
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("tests/gitlab")

    static var env: [String: String] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(".env"), encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        return values
    }

    static var token: String? { env["BONSAI_TOKEN"] }

    static let isAvailable: Bool = {
        guard let token else { return false }
        var request = URLRequest(url: server.appendingPathComponent("api/v4/user"), timeoutInterval: 3)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return ok
    }()

    static func client() -> GitLabClient {
        GitLabClient(server: server, token: token ?? "")
    }

    static func seed(_ name: String) async throws -> Int {
        let result = try await ProcessRunner.run("/bin/bash", [directory.appendingPathComponent("seed.sh").path, name],
                                                 environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
        guard result.succeeded, let id = result.output.split(separator: "\n").last.flatMap({ Int($0) }) else {
            throw GitError(command: "seed.sh", status: result.status, output: result.output)
        }
        return id
    }

    static func deleteProject(_ id: Int) async {
        let client = client()
        _ = try? await client.send(client.request("projects/\(id)", method: "DELETE"))
    }

    static func project(_ id: Int) async throws -> Project {
        let gitlab: GitLabProject = try await client().get("projects/\(id)")
        return Project(id: gitlab.id, name: gitlab.name, path: gitlab.path, webURL: gitlab.webURL, cloneURL: gitlab.cloneURL,
                       defaultBranch: gitlab.defaultBranch ?? "main", targetBranch: "main", setup: "./scripts/setup.sh", test: "make test")
    }
}
