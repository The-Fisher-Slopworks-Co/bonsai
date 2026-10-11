// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

@MainActor
@Observable
final class AccountModel {
    enum Connection: Equatable {
        case connected, tokenExpired, unreachable

        var title: String {
            switch self {
            case .connected: localized("settings.connected")
            case .tokenExpired: localized("settings.tokenExpired")
            case .unreachable: localized("settings.unreachable")
            }
        }

        var color: Color {
            switch self {
            case .connected: .green
            case .tokenExpired: .red
            case .unreachable: .orange
            }
        }
    }

    private let app: AppModel
    private let configuration: @Sendable () -> URLSessionConfiguration
    private(set) var connection: Connection?

    init(app: AppModel, configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.app = app
        self.configuration = configuration
    }

    var tokenText: String? {
        if connection == .tokenExpired { return localized("settings.tokenExpired").lowercased() }
        guard let date = app.store.account?.tokenExpiresAt else { return nil }
        return localized("settings.tokenUntil", date.formatted(date: .numeric, time: .omitted))
    }

    func refresh() async {
        guard let account = app.store.account, let token = app.store.token else { return }
        if let expires = account.tokenExpiresAt, expires < Date() {
            connection = .tokenExpired
            return
        }
        let client = GitLabClient(
            server: account.server, token: token, trustedFingerprint: account.trustedFingerprint,
            configuration: configuration())
        do {
            app.store.fillGitIdentity(from: try await client.user())
            connection = .connected
        } catch GitLabError.badToken {
            connection = .tokenExpired
        } catch {
            connection = .unreachable
        }
    }

    func setTrust(_ on: Bool) async {
        guard var account = app.store.account, let token = app.store.token else { return }
        if !on {
            account.trustedFingerprint = nil
            app.store.account = account
            app.store.saveTrustedCertificate(nil)
            await refresh()
            return
        }
        let probe = GitLabClient(server: account.server, token: token, configuration: configuration())
        guard case GitLabError.certificate(let fingerprint?)? = await Self.failure(of: probe) else { return }
        let pinned = GitLabClient(
            server: account.server, token: token, trustedFingerprint: fingerprint, configuration: configuration())
        guard (try? await pinned.user()) != nil else { return }
        account.trustedFingerprint = fingerprint
        app.store.account = account
        app.store.saveTrustedCertificate(pinned.acceptedCertificate)
        await refresh()
    }

    private static func failure(of client: GitLabClient) async -> GitLabError? {
        do {
            _ = try await client.user()
            return nil
        } catch let error as GitLabError {
            return error
        } catch {
            return nil
        }
    }
}
