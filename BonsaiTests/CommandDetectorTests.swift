// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct CommandDetectorTests {
    func detect(_ files: [String: String]) async throws -> DetectedCommands? {
        try await CommandDetector.detect(files: files.keys.filter { !$0.contains("/") }) { files[$0] }
    }

    @Test func makefileWithSetupScript() async throws {
        let found = try await detect(["Makefile": "test:\n\t./run.sh\n", "scripts/setup.sh": "#!/bin/sh"])
        #expect(found == DetectedCommands(setup: "./scripts/setup.sh", test: "make test", source: "Makefile"))
    }

    @Test func makefileSetupTarget() async throws {
        let found = try await detect([
            "Makefile": "CC := cc\n.PHONY: test deps\ndeps:\n\tpip install\ntest: deps\n\tpytest\n"
        ])
        #expect(found == DetectedCommands(setup: "make deps", test: "make test", source: "Makefile"))
    }

    @Test func makefileWithoutTestFallsThrough() async throws {
        let found = try await detect([
            "Makefile": "build:\n\tcc\n", "package.json": #"{"scripts": {"test": "jest"}}"#, "package-lock.json": "{}",
        ])
        #expect(found == DetectedCommands(setup: "npm ci", test: "npm test", source: "package.json"))
    }

    @Test func npmPlaceholderIsIgnored() async throws {
        let found = try await detect([
            "package.json": #"{"scripts": {"test": "echo \"Error: no test specified\" && exit 1"}}"#
        ])
        #expect(found == nil)
    }

    @Test func yarnAndPnpm() async throws {
        #expect(
            try await detect(["package.json": #"{"scripts": {"test": "vitest"}}"#, "yarn.lock": ""])?.test
                == "yarn test")
        #expect(
            try await detect(["package.json": #"{"scripts": {"test": "vitest"}}"#, "pnpm-lock.yaml": ""])?.setup
                == "pnpm install --frozen-lockfile")
        #expect(try await detect(["package.json": #"{"scripts": {"test": "vitest"}}"#])?.setup == "npm install")
    }

    @Test func otherEcosystems() async throws {
        #expect(
            try await detect(["Cargo.toml": ""])
                == DetectedCommands(setup: "", test: "cargo test", source: "Cargo.toml"))
        #expect(try await detect(["go.mod": ""])?.test == "go test ./...")
        #expect(
            try await detect(["mix.exs": ""])
                == DetectedCommands(setup: "mix deps.get", test: "mix test", source: "mix.exs"))
        #expect(try await detect(["Package.swift": ""])?.test == "swift test")
    }

    @Test func nothingFound() async throws {
        #expect(try await detect(["README.md": "hi"]) == nil)
    }

    @Test func makeTargets() {
        let targets = CommandDetector.makeTargets(
            "VAR = 1\nX := y\n%.o: %.c\n\ttest:\nall test: build\n# c: d\n.PHONY: all\n$(OUT): x\n")
        #expect(targets == ["all", "test"])
    }
}
