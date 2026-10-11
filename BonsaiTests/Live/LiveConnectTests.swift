import Foundation
import Testing

@testable import Bonsai

@MainActor
@Suite(.serialized, .enabled(if: LiveGitLab.isAvailable, "local GitLab is not running"))
struct LiveConnectTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-live-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    @Test(.timeLimit(.minutes(10))) func connectAddProjectAndProcessMRs() async throws {
        let name = "e2e-connect-\(UUID().uuidString.prefix(6).lowercased())"
        let id = try await LiveGitLab.seed(name)
        let store = Store(directory: dir, keychain: keychain)
        defer {
            store.signOut()
            try? FileManager.default.removeItem(at: dir)
        }

        let connect = ConnectModel(store: store)
        connect.server = "localhost:8929"
        connect.token = "glpat-wrong"
        #expect(await !connect.connect())
        #expect(connect.phase == .badToken)
        #expect(!connect.trustShown)
        connect.server = "http://localhost:8929"
        connect.token = try #require(LiveGitLab.token)
        #expect(await connect.connect())
        #expect(connect.phase == .connected(username: "bonsai"))
        #expect(store.account?.tokenExpiresAt != nil)

        let workspace = Workspace(store: store)
        let sheet = AddProjectModel(client: try #require(workspace.client()), excluded: [], debounce: .milliseconds(1))
        sheet.query = name
        await sheet.settle()
        await sheet.settle()
        #expect(sheet.selected?.id == id)
        #expect(sheet.branch == "main")
        #expect(sheet.test == "make test")
        #expect(sheet.setup == "./scripts/setup.sh")
        #expect(sheet.detectedFrom == "Makefile")
        let project = try #require(sheet.project())

        workspace.pipelineConfig.ciPollInterval = 3
        workspace.add(project)
        await workspace.waitUntilIdle()
        let state = workspace.state(project)
        #expect(state.error == nil)
        #expect(
            Set(state.mergeRequests.map(\.sourceBranch)) == [
                "feature/behind", "feature/conflict", "feature/failing-test",
            ])
        let statuses = Dictionary(
            uniqueKeysWithValues: state.mergeRequests.map { ($0.sourceBranch, workspace.run($0).status) })
        #expect(statuses["feature/behind"] == .upToDate(pushed: true))
        #expect(statuses["feature/conflict"] == .conflict(files: ["README.md"]))
        #expect(statuses["feature/failing-test"] == .testsFailed)
        #expect(
            FileManager.default.fileExists(
                atPath: store.cloneDirectory(for: project).appendingPathComponent("Makefile").path))
        let config = try String(
            contentsOf: store.cloneDirectory(for: project).appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(!config.contains(LiveGitLab.token!))
        await LiveGitLab.deleteProject(id)
    }
}
