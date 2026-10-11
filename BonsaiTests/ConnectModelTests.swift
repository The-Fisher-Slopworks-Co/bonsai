import Foundation
import Testing

@testable import Bonsai

@MainActor
struct ConnectModelTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-connect-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    func model(_ handler: @escaping MockURLProtocol.Handler) -> (ConnectModel, Store, URL) {
        let server = MockURLProtocol.server(handler)
        let store = Store(directory: dir, keychain: keychain)
        let model = ConnectModel(store: store, configuration: { MockURLProtocol.configuration() })
        model.server = server.absoluteString
        model.token = "glpat-abc"
        return (model, store, server)
    }

    static let ok: MockURLProtocol.Handler = { request in
        if request.url!.path().hasSuffix("/personal_access_tokens/self") {
            return (200, json(#"{"id": 1, "name": "Bonsai", "scopes": ["api"], "expires_at": "2026-12-31"}"#))
        }
        return (200, json(#"{"id": 3, "username": "eugene", "name": "Eugene", "avatar_url": null}"#))
    }

    @Test func buttonNeedsBothFields() {
        let store = Store(directory: dir, keychain: keychain)
        let model = ConnectModel(store: store)
        #expect(!model.canConnect)
        model.server = "https://git.corp"
        #expect(!model.canConnect)
        model.token = "glpat"
        #expect(model.canConnect)
        model.server = "  "
        #expect(!model.canConnect)
    }

    @Test func successSavesAccountAndToken() async throws {
        let (model, store, server) = model(Self.ok)
        #expect(await model.connect())
        #expect(model.phase == .connected(username: "eugene"))
        #expect(!model.canConnect)
        let account = try #require(store.account)
        #expect(account.server == server)
        #expect(account.username == "eugene")
        #expect(account.tokenExpiresAt != nil)
        #expect(account.trustedFingerprint == nil)
        #expect(store.token == "glpat-abc")
        store.signOut()
    }

    @Test func badToken() async {
        let (model, store, _) = model { _ in (401, Data()) }
        #expect(await !model.connect())
        #expect(model.phase == .badToken)
        #expect(store.account == nil)
        #expect(model.canConnect)
    }

    @Test func unreachable() async {
        let (model, _, _) = model { _ in throw URLError(.cannotConnectToHost) }
        #expect(await !model.connect())
        #expect(model.phase == .unreachable)
        #expect(!model.trustShown)
    }

    @Test func notAGitLabServerIsUnreachable() async {
        let (model, _, _) = model { _ in (404, json("<html>")) }
        #expect(await !model.connect())
        #expect(model.phase == .unreachable)
    }

    @Test func editingClearsError() async {
        let (model, _, _) = model { _ in (401, Data()) }
        await model.connect()
        #expect(model.phase == .badToken)
        model.token = "glpat-new"
        #expect(model.phase == .idle)
    }

    @Test func certificateShowsTrustCheckbox() async {
        let (model, store, _) = model { _ in throw URLError(.serverCertificateUntrusted) }
        #expect(!model.trustShown)
        #expect(await !model.connect())
        #expect(model.phase == .certificate)
        #expect(model.trustShown)
        model.trust = true
        #expect(model.phase == .idle)
        #expect(store.account == nil)
    }

    @Test func expiryFailureDoesNotBlockSignIn() async throws {
        let (model, store, _) = model { request in
            if request.url!.path().hasSuffix("/personal_access_tokens/self") { return (404, Data()) }
            return (200, json(#"{"id": 3, "username": "eugene", "name": "Eugene", "avatar_url": null}"#))
        }
        #expect(await model.connect())
        #expect(store.account?.tokenExpiresAt == nil)
        store.signOut()
    }

    @Test func prefillsServerFromAccount() throws {
        let store = Store(directory: dir, keychain: keychain)
        try store.signIn(
            Account(server: URL(string: "https://git.corp")!, username: "u", name: "U", trustedFingerprint: "AA"),
            token: "t")
        defer { store.signOut() }
        let model = ConnectModel(store: store)
        #expect(model.server == "https://git.corp")
        #expect(model.token.isEmpty)
        #expect(model.trustShown)
        #expect(model.trust)
    }
}
