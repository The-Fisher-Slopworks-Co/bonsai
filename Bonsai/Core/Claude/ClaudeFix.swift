// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct ClaudeFix: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case tests, ci, conflict
    }

    enum Phase: String, Codable, Sendable {
        case fixing
        case checking
        case ready
        case pushing
        case ci
        case pushed
        case gaveUp
        case rejected
        case stopped
        case reverted
        case terminal
    }

    var kind: Kind
    var phase: Phase
    var attempt = 1
    var maxAttempts: Int
    var job: String?
    var sessionID: String?
    var summary = ""
    var commitMessage = ""
    var stages: [Stage]
    var worktree: String
    var baseSHA: String
    var pushedSHA: String?
    var files: [FixFile] = []
    var testsTouched = false
    var ownCode = false
    var startedAt: Date?

    var isActive: Bool {
        switch phase {
        case .fixing, .checking, .ready, .pushing, .ci, .terminal: true
        default: false
        }
    }

    subscript(kind: StageKind) -> Stage {
        get { stages.first { $0.kind == kind } ?? Stage(kind: kind) }
        set {
            if let index = stages.firstIndex(where: { $0.kind == kind }) { stages[index] = newValue }
        }
    }

    static func stageKinds(for kind: Kind) -> [StageKind] {
        switch kind {
        case .tests, .ci: [.claude, .retest, .push, .ci]
        case .conflict: [.claude, .continueRebase, .setup, .retest, .push, .ci]
        }
    }

    var resolvedConflicts: Int {
        files.reduce(0) { $0 + $1.conflicts.count }
    }
}

struct FixFile: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case diff
        case conflict
        case lock
    }

    var path: String
    var kind: Kind
    var added = 0
    var removed = 0
    var hunks: [DiffHunk] = []
    var conflicts: [ResolvedConflict] = []
    var note: String?

    var hasOwnCode: Bool { conflicts.contains { $0.source == .own } }
}

struct DiffHunk: Codable, Equatable, Sendable {
    struct Line: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case context, added, removed }
        var kind: Kind
        var text: String
    }

    var header: String
    var oldStart: Int
    var newStart: Int
    var lines: [Line]
}

struct ResolvedConflict: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case main, branch, both, own
    }

    struct Line: Codable, Equatable, Sendable {
        enum Origin: String, Codable, Sendable { case main, branch, own, context }
        var number: Int?
        var text: String
        var origin: Origin
    }

    var startLine: Int
    var endLine: Int
    var source: Source
    var lines: [Line]
    var dropped: [Line]
}
