// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Observation

@MainActor
@Observable
final class Store {
    let directory: URL
    let workDirectory: URL
    let keychain: Keychain

    var account: Account? { didSet { write(account, to: "account.json") } }
    var settings: Settings { didSet { write(settings, to: "settings.json") } }
    var projects: [Project] { didSet { write(projects, to: "projects.json") } }
    var pausedUntil: Date? { didSet { write(pausedUntil, to: "paused.json") } }

    init(directory: URL = Store.defaultDirectory, workDirectory: URL? = nil, keychain: Keychain = Keychain()) {
        self.directory = directory
        self.workDirectory =
            workDirectory ?? (directory == Self.defaultDirectory ? Self.defaultWorkDirectory : directory)
        self.keychain = keychain
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        account = Self.read(Account.self, from: directory.appendingPathComponent("account.json"))
        settings = Self.read(Settings.self, from: directory.appendingPathComponent("settings.json")) ?? Settings()
        projects = Self.read([Project].self, from: directory.appendingPathComponent("projects.json")) ?? []
        pausedUntil = Self.read(Date.self, from: directory.appendingPathComponent("paused.json"))
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bonsai", isDirectory: true)
    }

    static var defaultWorkDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Developer/Bonsai", isDirectory: true)
    }

    var clonesDirectory: URL { workDirectory.appendingPathComponent("clones", isDirectory: true) }

    var fixesDirectory: URL { workDirectory.appendingPathComponent("fixes", isDirectory: true) }

    func cloneDirectory(for project: Project) -> URL {
        clonesDirectory.appendingPathComponent(project.path, isDirectory: true)
    }

    var certificateFile: URL { directory.appendingPathComponent("trusted-certificate.pem") }

    var gitAuth: GitAuth? {
        guard let account, let token else { return nil }
        let pinned = account.trustedFingerprint != nil && FileManager.default.fileExists(atPath: certificateFile.path)
        return GitAuth(token: token, caFile: pinned ? certificateFile : nil, server: account.server)
    }

    func saveTrustedCertificate(_ der: Data?) {
        if let der {
            try? TrustDelegate.pem(der: der).write(to: certificateFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: certificateFile)
        }
    }

    var token: String? {
        account.flatMap { keychain.read(account: $0.server.absoluteString) }
    }

    func fillGitIdentity(from user: GitLabUser) {
        var identity = settings.gitIdentity
        if identity.name.isEmpty { identity.name = user.name }
        if identity.email.isEmpty { identity.email = user.commitEmail ?? user.email ?? "" }
        if identity != settings.gitIdentity { settings.gitIdentity = identity }
    }

    var isSignedIn: Bool { account != nil && token != nil }

    func signIn(_ account: Account, token: String) throws {
        try keychain.write(token, account: account.server.absoluteString)
        self.account = account
    }

    func signOut() {
        if let account { keychain.delete(account: account.server.absoluteString) }
        account = nil
    }

    func loadRuns() -> [String: MRRun] {
        Self.read([String: MRRun].self, from: directory.appendingPathComponent("runs.json")) ?? [:]
    }

    func saveRuns(_ runs: [String: MRRun]) {
        write(runs, to: "runs.json")
    }

    func loadMainChecks() -> [Int: MainCheck] {
        Self.read([Int: MainCheck].self, from: directory.appendingPathComponent("main-checks.json")) ?? [:]
    }

    func saveMainChecks(_ checks: [Int: MainCheck]) {
        write(checks, to: "main-checks.json")
    }

    func loadMergeRequests() -> [Int: [MergeRequest]] {
        Self.read([Int: [MergeRequest]].self, from: directory.appendingPathComponent("merge-requests.json")) ?? [:]
    }

    func saveMergeRequests(_ mrs: [Int: [MergeRequest]]) {
        write(mrs, to: "merge-requests.json")
    }

    private func write<T: Encodable>(_ value: T?, to name: String) {
        let url = directory.appendingPathComponent(name)
        guard let value else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
