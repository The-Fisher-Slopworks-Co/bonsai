// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BONSAI_LIVE_LOGIN"] != nil && LiveGitLab.isAvailable))
struct LiveLoginTool {
    @Test func signInAppToLocalGitLab() async throws {
        let id = try #require(Int(ProcessInfo.processInfo.environment["BONSAI_LIVE_LOGIN"] ?? ""))
        let store = Store()
        let user = try await LiveGitLab.client().user()
        try store.signIn(
            Account(server: LiveGitLab.server, username: user.username, name: user.name),
            token: try #require(LiveGitLab.token))
        let project = try await LiveGitLab.project(id)
        if !store.projects.contains(where: { $0.id == id }) { store.projects.append(project) }
    }
}
