// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

@testable import Bonsai

struct TempRepo {
    let root: URL
    let origin: URL
    let seed: URL

    init() async throws {
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("bonsai-git-\(UUID().uuidString)")
        origin = root.appendingPathComponent("origin.git")
        seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try await sh("git init -q --bare -b main \(origin.path)", in: root)
        try await sh("git init -q -b main && git remote add origin \(origin.path)", in: seed)
        try write("README.md", "hello\n")
        try await commit("init")
        try await sh("git push -q origin main", in: seed)
    }

    func write(_ name: String, _ text: String, in dir: URL? = nil) throws {
        let url = (dir ?? seed).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func commit(_ message: String, in dir: URL? = nil) async throws {
        try await sh(
            "git add -A && git -c user.name=Seed -c user.email=seed@example.com commit -q -m '\(message)'",
            in: dir ?? seed)
    }

    @discardableResult
    func sh(_ script: String, in dir: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", script], in: dir, environment: ["GIT_CONFIG_NOSYSTEM": "1"])
        guard result.succeeded else { throw GitError(command: script, status: result.status, output: result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
