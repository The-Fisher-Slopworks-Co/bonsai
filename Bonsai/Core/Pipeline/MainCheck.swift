// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct MainCheck: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case checking, passed, failed, broken
        case missing, fixing, ready, rejected, stopped
    }

    struct Commands: Codable, Equatable, Sendable {
        var setup: String
        var test: String

        init(setup: String, test: String) {
            self.setup = setup.trimmingCharacters(in: .whitespacesAndNewlines)
            self.test = test.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        init(_ project: Project) {
            self.init(setup: project.setup, test: project.test)
        }
    }

    struct Proposal: Codable, Equatable, Sendable {
        var stages: [Stage]
        var commands: Commands?
        var summary = ""
        var sessionID: String?

        subscript(kind: StageKind) -> Stage {
            get { stages.first { $0.kind == kind } ?? Stage(kind: kind) }
            set {
                if let index = stages.firstIndex(where: { $0.kind == kind }) { stages[index] = newValue }
            }
        }
    }

    var phase: Phase = .checking
    var sha: String
    var commands: Commands
    var stages: [Stage] = []
    var lastPassed: Commands?
    var pick = false
    var proposal: Proposal?
    var finishedAt: Date?

    subscript(kind: StageKind) -> Stage {
        get { stages.first { $0.kind == kind } ?? Stage(kind: kind) }
        set {
            if let index = stages.firstIndex(where: { $0.kind == kind }) { stages[index] = newValue }
        }
    }

    var failedStage: StageKind? {
        stages.first { $0.state == .failed && $0.kind != .ci }?.kind
    }
}

extension MainCheck: Recordable {
    mutating func append(_ line: LogLine, to kind: StageKind, fix: Bool) {
        if fix {
            proposal?[kind].append(line)
        } else {
            self[kind].append(line)
        }
    }
}
