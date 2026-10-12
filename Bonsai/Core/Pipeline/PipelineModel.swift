// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

enum StageKind: String, Codable, CaseIterable, Sendable {
    case rebase, setup, test, push, ci
    case claude, continueRebase, retest
    case checkout

    static let pipeline: [StageKind] = [.rebase, .setup, .test, .push, .ci]
}

enum StageState: String, Codable, Sendable {
    case pending, running, done, failed, skipped
}

struct LogLine: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case command
        case output
        case ok
        case error
        case note
        case claude
        case tool
    }

    var text: String
    var kind: Kind
}

struct Stage: Codable, Equatable, Sendable {
    enum Caption: String, Codable, Sendable {
        case onto, notNeeded, ciPassed, conflictFiles, pushRejected, ciFailed, command, pipeline, none
        case claudeAttempt, claudeChanged, claudeResolved, claudeFailed
        case afterFix
        case ref, mainCiPassed, mainCiFailed
    }

    var kind: StageKind
    var state: StageState = .pending
    var caption: Caption = .none
    var detail = ""
    var startedAt: Date?
    var duration: TimeInterval?
    var log: [LogLine] = []

    static let maxLogLines = 2000

    mutating func append(_ line: LogLine) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }
}

enum MRStatus: Codable, Equatable, Sendable {
    case behind(commits: Int)
    case running(StageKind, attempt: Int)
    case upToDate(pushed: Bool)
    case testsFailed
    case ciFailed(job: String)
    case conflict(files: [String])
    case branchChanged
    case pushFailed(message: String)
    case error(message: String)
    case unknown

    var isFinal: Bool {
        switch self {
        case .running, .unknown: false
        default: true
        }
    }
}

struct MRRun: Codable, Equatable, Sendable {
    var status: MRStatus = .unknown
    var stages: [Stage] = StageKind.pipeline.map { Stage(kind: $0) }
    var attempt = 1
    var headSHA: String?
    var baseSHA: String?
    var pushedSHA: String?
    var pipelineID: Int?
    var failedJobID: Int?
    var finishedAt: Date?
    var fix: ClaudeFix?

    subscript(kind: StageKind) -> Stage {
        get { stages.first { $0.kind == kind } ?? Stage(kind: kind) }
        set {
            if let index = stages.firstIndex(where: { $0.kind == kind }) { stages[index] = newValue }
        }
    }

    mutating func resetStages() {
        stages = StageKind.pipeline.map { Stage(kind: $0) }
    }
}

extension MRRun: Recordable {
    mutating func append(_ line: LogLine, to kind: StageKind, fix: Bool) {
        if fix {
            self.fix?[kind].append(line)
        } else {
            self[kind].append(line)
        }
    }
}
