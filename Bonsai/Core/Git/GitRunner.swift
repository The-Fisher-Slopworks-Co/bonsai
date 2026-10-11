import Foundation

struct GitError: Error, Equatable {
    var command: String
    var status: Int32
    var output: String
}

struct GitAuth: Sendable {
    var token: String
    var caFile: URL?
    var server: URL?

    var environment: [String: String] {
        var pairs: [(String, String)] = []
        let basic = Data("oauth2:\(token)".utf8).base64EncodedString()
        pairs.append(("http.extraHeader", "Authorization: Basic \(basic)"))
        if let caFile, let server {
            pairs.append(("http.\(server.absoluteString)/.sslCAInfo", caFile.path))
        }
        var env = ["GIT_CONFIG_COUNT": String(pairs.count)]
        for (i, pair) in pairs.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = pair.0
            env["GIT_CONFIG_VALUE_\(i)"] = pair.1
        }
        return env
    }
}

struct GitRunner: Sendable {
    var directory: URL
    var auth: GitAuth?
    var identity: GitIdentity?
    var git = "/usr/bin/git"

    static let baseEnvironment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/true",
        "LC_ALL": "C",
        "GIT_EDITOR": "true",
        "GIT_SEQUENCE_EDITOR": "true",
        "GIT_MERGE_AUTOEDIT": "no",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    ]

    var environment: [String: String] {
        var env = Self.baseEnvironment.merging(auth?.environment ?? [:]) { _, new in new }
        if let identity {
            for (key, value) in [("NAME", identity.name), ("EMAIL", identity.email)] where !value.isEmpty {
                env["GIT_AUTHOR_\(key)"] = value
                env["GIT_COMMITTER_\(key)"] = value
            }
        }
        return env
    }

    @discardableResult
    func run(_ args: [String], in dir: URL? = nil, onLine: (@Sendable (String) -> Void)? = nil) async throws
        -> CommandResult
    {
        try await ProcessRunner.run(git, args, in: dir ?? directory, environment: environment, onLine: onLine)
    }

    @discardableResult
    func checked(_ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let result = try await run(args, onLine: onLine)
        guard result.succeeded else {
            throw GitError(command: "git " + args.joined(separator: " "), status: result.status, output: result.output)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRepository: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }

    func clone(_ url: URL, onLine: (@Sendable (String) -> Void)? = nil) async throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let result = try await run(
            ["clone", "--no-tags", url.absoluteString, directory.lastPathComponent], in: parent, onLine: onLine)
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: directory)
            throw GitError(command: "git clone", status: result.status, output: result.output)
        }
    }

    func fetch(onLine: (@Sendable (String) -> Void)? = nil) async throws {
        try await checked(["fetch", "--prune", "--no-tags", "origin"], onLine: onLine)
    }

    func revParse(_ ref: String) async throws -> String {
        try await checked(["rev-parse", "--verify", "--quiet", ref + "^{commit}"])
    }

    func behind(_ head: String, base: String) async throws -> Int {
        Int(try await checked(["rev-list", "--count", "\(head)..\(base)"])) ?? 0
    }

    var isClean: Bool {
        get async throws { try await checked(["status", "--porcelain"]).isEmpty }
    }

    func currentBranch() async throws -> String {
        try await checked(["rev-parse", "--abbrev-ref", "HEAD"])
    }
}
