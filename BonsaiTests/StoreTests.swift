import Foundation
import Testing
@testable import Bonsai

@MainActor
struct StoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-store-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    @Test func defaultsWhenEmpty() {
        let store = Store(directory: dir, keychain: keychain)
        #expect(store.account == nil)
        #expect(store.projects.isEmpty)
        #expect(store.settings == Settings())
        #expect(store.settings.interval == .every5)
        #expect(store.settings.parallel == 2)
        #expect(store.settings.skipLabel == "no-rebase")
        #expect(store.settings.dockIcon == false)
        #expect(store.settings.claude.attempts == 2)
        #expect(store.settings.notifications.started == false)
    }

    @Test func workDirectoryHasNoSpaces() {
        #expect(!Store.defaultWorkDirectory.path.contains(" "))
        #expect(Store(directory: dir, keychain: keychain).clonesDirectory.path.hasPrefix(dir.path))
    }

    @Test func gitIdentityFilledFromGitLabWithoutOverwriting() {
        let store = Store(directory: dir, keychain: keychain)
        store.fillGitIdentity(from: GitLabUser(id: 1, username: "e", name: "Eugene", email: "e@corp", commitEmail: "commit@corp"))
        #expect(store.settings.gitIdentity == GitIdentity(name: "Eugene", email: "commit@corp"))
        store.settings.gitIdentity.name = "Typed"
        store.settings.gitIdentity.email = ""
        store.fillGitIdentity(from: GitLabUser(id: 1, username: "e", name: "Other", email: "e@corp"))
        #expect(store.settings.gitIdentity == GitIdentity(name: "Typed", email: "e@corp"))
    }

    @Test func persistsAcrossInstances() throws {
        let store = Store(directory: dir, keychain: keychain)
        store.settings.parallel = 5
        store.settings.interval = .manual
        store.projects = [Project(id: 7, name: "app", path: "g/app", webURL: URL(string: "https://x/g/app")!,
                                  cloneURL: URL(string: "https://x/g/app.git")!, defaultBranch: "main",
                                  targetBranch: "main", setup: "", test: "make test")]
        let account = Account(server: URL(string: "https://x")!, username: "me", name: "Me")
        try store.signIn(account, token: "glpat-secret")

        let again = Store(directory: dir, keychain: keychain)
        #expect(again.settings.parallel == 5)
        #expect(again.settings.interval == .manual)
        #expect(again.projects.map(\.path) == ["g/app"])
        #expect(again.account == account)
        #expect(again.token == "glpat-secret")

        again.signOut()
        #expect(Store(directory: dir, keychain: keychain).account == nil)
        #expect(keychain.read(account: "https://x") == nil)
    }

    @Test func tokenIsNotWrittenToDisk() throws {
        let store = Store(directory: dir, keychain: keychain)
        try store.signIn(Account(server: URL(string: "https://x")!, username: "me", name: "Me"), token: "glpat-secret")
        defer { store.signOut() }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            #expect(!text.contains("glpat-secret"))
        }
    }

    @Test func partialSettingsFileKeepsDefaults() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"parallel": 4}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let store = Store(directory: dir, keychain: keychain)
        #expect(store.settings.parallel == 4)
        #expect(store.settings.interval == .every5)
    }
}

struct KeychainTests {
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    @Test func writeReadUpdateDelete() throws {
        #expect(keychain.read(account: "a") == nil)
        try keychain.write("one", account: "a")
        #expect(keychain.read(account: "a") == "one")
        try keychain.write("two", account: "a")
        #expect(keychain.read(account: "a") == "two")
        keychain.delete(account: "a")
        #expect(keychain.read(account: "a") == nil)
    }
}
