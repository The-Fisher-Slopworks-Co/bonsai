import Foundation

struct DetectedCommands: Equatable, Sendable {
    var setup: String
    var test: String
    var source: String
}

enum CommandDetector {
    static func detect(files: [String], read: @Sendable (String) async throws -> String?) async throws -> DetectedCommands? {
        let names = Set(files)
        let setupScript = names.isEmpty ? nil : try await setupScriptPath(read: read)

        if names.contains("Makefile"), let makefile = try await read("Makefile") {
            let targets = makeTargets(makefile)
            if targets.contains("test") {
                let setup = setupScript ?? ["setup", "deps", "install", "bootstrap"].first(where: targets.contains).map { "make \($0)" } ?? ""
                return DetectedCommands(setup: setup, test: "make test", source: "Makefile")
            }
        }
        if names.contains("package.json"), let package = try await read("package.json"), hasNpmTest(package) {
            if names.contains("pnpm-lock.yaml") {
                return DetectedCommands(setup: setupScript ?? "pnpm install --frozen-lockfile", test: "pnpm test", source: "package.json")
            }
            if names.contains("yarn.lock") {
                return DetectedCommands(setup: setupScript ?? "yarn install --frozen-lockfile", test: "yarn test", source: "package.json")
            }
            let install = names.contains("package-lock.json") || names.contains("npm-shrinkwrap.json") ? "npm ci" : "npm install"
            return DetectedCommands(setup: setupScript ?? install, test: "npm test", source: "package.json")
        }
        if names.contains("Cargo.toml") {
            return DetectedCommands(setup: setupScript ?? "", test: "cargo test", source: "Cargo.toml")
        }
        if names.contains("go.mod") {
            return DetectedCommands(setup: setupScript ?? "", test: "go test ./...", source: "go.mod")
        }
        if names.contains("mix.exs") {
            return DetectedCommands(setup: setupScript ?? "mix deps.get", test: "mix test", source: "mix.exs")
        }
        if names.contains("Package.swift") {
            return DetectedCommands(setup: setupScript ?? "", test: "swift test", source: "Package.swift")
        }
        return nil
    }

    private static func setupScriptPath(read: @Sendable (String) async throws -> String?) async throws -> String? {
        try await read("scripts/setup.sh") != nil ? "./scripts/setup.sh" : nil
    }

    static func makeTargets(_ makefile: String) -> Set<String> {
        var targets = Set<String>()
        for line in makefile.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "." else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") { continue }
            for name in line[..<colon].split(separator: " ") where !name.contains("$") && !name.contains("%") && !name.contains("=") {
                targets.insert(String(name))
            }
        }
        return targets
    }

    static func hasNpmTest(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any],
              let test = scripts["test"] as? String else { return false }
        return !test.contains("no test specified")
    }
}
