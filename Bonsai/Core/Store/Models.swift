// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct Account: Codable, Equatable, Sendable {
    var server: URL
    var username: String
    var name: String
    var avatarURL: URL?
    var tokenExpiresAt: Date?
    var trustedFingerprint: String?
}

enum ClaudeMode: String, Codable, CaseIterable, Sendable {
    case inherit, manual, off
}

struct Project: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    var path: String
    var webURL: URL
    var cloneURL: URL
    var defaultBranch: String
    var targetBranch: String
    var setup: String
    var test: String
    var paused: Bool = false
    var claude: ClaudeMode = .inherit
    var rules: String = ""
    var environment: String = ""

    var environmentChecks: [String] {
        environment.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var localCopy: String = ""
    var copied: String = ""

    var copiedPaths: [String] {
        copied.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var copiesLocally: Bool { !localCopy.isEmpty && !copiedPaths.isEmpty }

    var localCopyPath: String? { localCopy.isEmpty ? nil : (localCopy as NSString).expandingTildeInPath }

    var jobs: String = ""
    var reruns = 0

    var ciJobs: [String] {
        jobs.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func claudeFixes(job: String) -> Bool {
        let jobs = ciJobs
        return jobs.isEmpty || jobs.contains(job)
    }

    static let rerunsRange = 0...3
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        webURL = try c.decode(URL.self, forKey: .webURL)
        cloneURL = try c.decode(URL.self, forKey: .cloneURL)
        defaultBranch = try c.decode(String.self, forKey: .defaultBranch)
        targetBranch = try c.decode(String.self, forKey: .targetBranch)
        setup = try c.decode(String.self, forKey: .setup)
        test = try c.decode(String.self, forKey: .test)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        claude = try c.decodeIfPresent(ClaudeMode.self, forKey: .claude) ?? .inherit
        rules = try c.decodeIfPresent(String.self, forKey: .rules) ?? ""
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? ""
        localCopy = try c.decodeIfPresent(String.self, forKey: .localCopy) ?? ""
        copied = try c.decodeIfPresent(String.self, forKey: .copied) ?? ""
        jobs = try c.decodeIfPresent(String.self, forKey: .jobs) ?? ""
        reruns = try c.decodeIfPresent(Int.self, forKey: .reruns) ?? 0
    }
}

struct MergeRequest: Codable, Equatable, Identifiable, Sendable {
    var projectID: Int
    var iid: Int
    var title: String
    var author: String
    var sourceBranch: String
    var targetBranch: String
    var webURL: URL
    var sha: String
    var draft: Bool
    var labels: [String]

    var id: String { "\(projectID)!\(iid)" }
}

enum CheckInterval: Int, Codable, CaseIterable, Sendable {
    case everyMinute = 1
    case every5 = 5
    case every15 = 15
    case every30 = 30
    case manual = 0

    var seconds: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue * 60) }
}

enum MRScope: String, Codable, Sendable {
    case mine, all
}

enum PushMode: String, Codable, Sendable {
    case review, auto
}

struct NotificationSettings: Codable, Equatable, Sendable {
    var claudeReady = true
    var needsMe = true
    var noConnection = true
    var updated = true
    var started = false
    var quietWhileWindowOpen = true
}

struct ClaudeSettings: Codable, Equatable, Sendable {
    var path: String?
    var onConflict = false
    var onTests = true
    var onCI = true
    var push: PushMode = .review
    var attempts = 2
    var rules: String?
}

struct GitIdentity: Codable, Equatable, Sendable {
    var name = ""
    var email = ""
}

struct Settings: Codable, Equatable, Sendable {
    var interval: CheckInterval = .every5
    var parallel = 2
    var scope: MRScope = .mine
    var skipDrafts = true
    var skipLabelEnabled = true
    var skipLabel = "no-rebase"
    var openAtLogin = true
    var dockIcon = false
    var notifications = NotificationSettings()
    var claude = ClaudeSettings()
    var gitIdentity = GitIdentity()

    static let parallelRange = 1...8
    static let attemptsRange = 1...3
}

extension Settings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        interval = try c.decodeIfPresent(CheckInterval.self, forKey: .interval) ?? d.interval
        parallel = try c.decodeIfPresent(Int.self, forKey: .parallel) ?? d.parallel
        scope = try c.decodeIfPresent(MRScope.self, forKey: .scope) ?? d.scope
        skipDrafts = try c.decodeIfPresent(Bool.self, forKey: .skipDrafts) ?? d.skipDrafts
        skipLabelEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipLabelEnabled) ?? d.skipLabelEnabled
        skipLabel = try c.decodeIfPresent(String.self, forKey: .skipLabel) ?? d.skipLabel
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? d.openAtLogin
        dockIcon = try c.decodeIfPresent(Bool.self, forKey: .dockIcon) ?? d.dockIcon
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? d.notifications
        claude = try c.decodeIfPresent(ClaudeSettings.self, forKey: .claude) ?? d.claude
        gitIdentity = try c.decodeIfPresent(GitIdentity.self, forKey: .gitIdentity) ?? d.gitIdentity
    }
}
