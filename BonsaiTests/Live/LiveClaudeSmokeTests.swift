import Foundation
import Testing
@testable import Bonsai

@Suite(.enabled(if: ProcessInfo.processInfo.environment["BONSAI_LIVE_CLAUDE"] == "1"))
struct LiveClaudeSmokeTests {
    @Test(.timeLimit(.minutes(1)))
    func pong() async throws {
        let path = try #require(await ClaudeCLI.locate(custom: nil))
        let lines = Lines()
        let result = try await ProcessRunner.run("/bin/zsh", ["-lc", "\"$0\" \"$@\"", path, "-p", "Reply with the word pong.", "--output-format", "stream-json",
                                                              "--verbose", "--model", "sonnet", "--effort", "low", "--debug", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"],
                                                 in: URL(fileURLWithPath: "/tmp")) { lines.add($0); print("SMOKE>", $0.prefix(200)) }
        print("SMOKE status", result.status)
        for line in lines.all.prefix(80) { print("SMOKE", line.prefix(200)) }
        #expect(lines.all.contains { $0.contains("\"type\":\"result\"") })
    }

    @Test(.timeLimit(.minutes(1)))
    func pongDirect() async throws {
        let path = try #require(await ClaudeCLI.locate(custom: nil))
        let result = try await ProcessRunner.run(path, ["-p", "Reply with the word pong.", "--output-format", "stream-json", "--verbose", "--model", "sonnet", "--effort", "low", "--debug", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"],
                                                 in: URL(fileURLWithPath: "/tmp")) { print("DIRECT>", $0.prefix(200)) }
        print("DIRECT status", result.status)
    }
}
