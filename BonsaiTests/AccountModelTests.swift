import Foundation
import Testing
@testable import Bonsai

@MainActor
struct AccountModelTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-acc-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    func model(status: Int, expires: Date? = nil, pinned: String? = nil) throws -> (AccountModel, AppModel) {
        let server = MockURLProtocol.server { _ in (status, json(#"{"id": 1, "username": "u", "name": "U", "avatar_url": null}"#)) }
        let store = Store(directory: dir, keychain: keychain)
        try store.signIn(Account(server: server, username: "u", name: "U", tokenExpiresAt: expires, trustedFingerprint: pinned), token: "t")
        let app = AppModel(store: store)
        return (AccountModel(app: app, configuration: { MockURLProtocol.configuration() }), app)
    }

    @Test func connected() async throws {
        let (model, app) = try model(status: 200, expires: Date().addingTimeInterval(86400))
        defer { app.store.signOut() }
        await model.refresh()
        #expect(model.connection == .connected)
        #expect(model.tokenText?.isEmpty == false)
    }

    @Test func rejectedTokenIsExpired() async throws {
        let (model, app) = try model(status: 401)
        defer { app.store.signOut() }
        await model.refresh()
        #expect(model.connection == .tokenExpired)
        #expect(model.tokenText == L("settings.tokenExpired").lowercased())
    }

    @Test func pastExpiryIsExpiredWithoutRequest() async throws {
        let (model, app) = try model(status: 200, expires: Date().addingTimeInterval(-60))
        defer { app.store.signOut() }
        await model.refresh()
        #expect(model.connection == .tokenExpired)
    }

    @Test func serverErrorIsUnreachable() async throws {
        let (model, app) = try model(status: 502)
        defer { app.store.signOut() }
        await model.refresh()
        #expect(model.connection == .unreachable)
    }

    @Test func turningTrustOffRemovesPin() async throws {
        let (model, app) = try model(status: 200, pinned: "AA:BB")
        defer { app.store.signOut() }
        try "pem".write(to: app.store.certificateFile, atomically: true, encoding: .utf8)
        await model.setTrust(false)
        #expect(app.store.account?.trustedFingerprint == nil)
        #expect(!FileManager.default.fileExists(atPath: app.store.certificateFile.path))
    }

    @Test func trustOnWithValidCertificateChangesNothing() async throws {
        let (model, app) = try model(status: 200)
        defer { app.store.signOut() }
        await model.setTrust(true)
        #expect(app.store.account?.trustedFingerprint == nil)
    }
}
