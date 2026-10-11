// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Observation

@MainActor
@Observable
final class ConnectModel {
    enum Phase: Equatable {
        case idle, checking
        case connected(username: String)
        case badToken, unreachable, certificate
    }

    var server: String { didSet { if server != oldValue { resetError() } } }
    var token: String { didSet { if token != oldValue { resetError() } } }
    var reveal = false
    var trust = false { didSet { if trust != oldValue { resetError() } } }
    private(set) var trustShown = false
    private(set) var phase: Phase = .idle

    private let store: Store
    private let configuration: () -> URLSessionConfiguration
    private var presentedFingerprint: String?

    init(store: Store, configuration: @escaping () -> URLSessionConfiguration = { .ephemeral }) {
        self.store = store
        self.configuration = configuration
        server = store.account?.server.absoluteString ?? ""
        token = ""
        if let pinned = store.account?.trustedFingerprint {
            presentedFingerprint = pinned
            trust = true
            trustShown = true
        }
    }

    var isFilled: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isConnected: Bool { if case .connected = phase { true } else { false } }

    var canConnect: Bool { isFilled && phase != .checking && !isConnected }

    var tokenPageURL: URL { GitLabClient.tokenPageURL(server: server) }

    @discardableResult
    func connect() async -> Bool {
        guard canConnect else { return false }
        guard let url = GitLabClient.normalize(server) else {
            phase = .unreachable
            return false
        }
        phase = .checking
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinned = trust ? presentedFingerprint : nil
        var candidates = [url]
        if !server.contains("://"),
            let plain = GitLabClient.normalize("http://" + server.trimmingCharacters(in: .whitespaces))
        {
            candidates.append(plain)
        }
        var outcome: Phase = .unreachable
        for candidate in candidates {
            let client = GitLabClient(
                server: candidate, token: secret, trustedFingerprint: pinned, configuration: configuration())
            do {
                let user = try await client.user()
                let expires = try? await client.tokenExpiry()
                let account = Account(
                    server: candidate, username: user.username, name: user.name, avatarURL: user.avatarURL,
                    tokenExpiresAt: expires ?? nil, trustedFingerprint: pinned)
                try store.signIn(account, token: secret)
                store.fillGitIdentity(from: user)
                store.saveTrustedCertificate(pinned == nil ? nil : client.acceptedCertificate)
                phase = .connected(username: user.username)
                return true
            } catch GitLabError.badToken {
                outcome = .badToken
            } catch GitLabError.certificate(let fingerprint) {
                if let fingerprint { presentedFingerprint = fingerprint }
                trustShown = true
                outcome = .certificate
            } catch {
                outcome = .unreachable
                continue
            }
            break
        }
        phase = outcome
        return false
    }

    private func resetError() {
        if phase != .checking && !isConnected { phase = .idle }
    }
}
