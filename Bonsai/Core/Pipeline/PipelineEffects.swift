// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

enum RebaseResult: Equatable, Sendable {
    case ok
    case conflict(files: [String])
}

enum PushResult: Equatable, Sendable {
    case ok
    case rejected
    case failed(String)
}

struct CIPipeline: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running, passed, failed
    }

    var id: Int
    var status: Status
}

struct CIJob: Equatable, Sendable {
    var id: Int
    var name: String
}

typealias LogSink = @Sendable (LogLine) -> Void

protocol PipelineEffects: Sendable {
    func fetch(log: @escaping LogSink) async throws
    func sha(_ ref: String) async throws -> String
    func behind(head: String, base: String) async throws -> Int
    func checkout(_ branch: String, log: @escaping LogSink) async throws
    func detach(_ ref: String, log: @escaping LogSink) async throws
    func rebase(onto ref: String, log: @escaping LogSink) async throws -> RebaseResult
    func copy(_ paths: [String], from localCopy: String, log: @escaping LogSink) async throws
    func abortRebase(log: @escaping LogSink) async
    func run(_ command: String, log: @escaping LogSink) async throws -> Bool
    func head() async throws -> String
    func push(_ branch: String, expected: String, log: @escaping LogSink) async throws -> PushResult
    func pipeline(sha: String) async throws -> CIPipeline?
    func failedJob(pipeline: Int) async throws -> CIJob?
    func sleep(_ seconds: TimeInterval) async throws
}
