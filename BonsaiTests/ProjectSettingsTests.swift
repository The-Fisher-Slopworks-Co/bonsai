// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

@MainActor
struct ProjectSettingsModelTests {
    @Test func saveNeedsChangesAndTests() {
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        #expect(!model.canSave)
        model.draft.setup = "npm ci"
        #expect(model.canSave)
        model.draft.test = "  "
        #expect(!model.canSave)
        model.draft.test = PipelineTests.project.test
        model.draft.setup = PipelineTests.project.setup
        #expect(!model.hasChanges)
        model.draft.claude = .off
        #expect(model.canSave)
    }

    @Test func savedTrimsCommands() {
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        model.draft.test = "  make check \n"
        model.draft.rules = " Не трогай migrations/ \n"
        let saved = model.saved()
        #expect(saved.test == "make check")
        #expect(saved.rules == "Не трогай migrations/")
    }

    @Test func savedKeepsOnlyNamedJobs() {
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        model.draft.jobs = " lint \n\n  test\n"
        model.draft.reruns = 2
        #expect(model.canSave)
        let saved = model.saved()
        #expect(saved.jobs == "lint\ntest")
        #expect(saved.ciJobs == ["lint", "test"])
        #expect(saved.reruns == 2)
    }

    @Test func oldProjectsDecodeWithoutJobs() throws {
        let json = #"""
            {"id": 1, "name": "app", "path": "g/app", "webURL": "https://x/g", "cloneURL": "https://x/g.git",
             "defaultBranch": "main", "targetBranch": "main", "setup": "", "test": "make test"}
            """#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.ciJobs.isEmpty)
        #expect(project.reruns == 0)
    }

    @Test func claudeProposalPrefillsAndTracksEdits() {
        let proposal = MainCheck.Proposal(
            stages: [],
            commands: MainCheck.Commands(setup: "docker compose up -d\n./scripts/setup.sh", test: "make test"),
            summary: "Тестам нужен Postgres.")
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil, proposal: proposal)
        #expect(model.draft.setup == "docker compose up -d\n./scripts/setup.sh")
        #expect(!model.isEdited)
        #expect(model.was(.setup) == "./scripts/setup.sh")
        #expect(model.was(.test) == nil)

        model.draft.test = "make check"
        #expect(model.isEdited)
        #expect(model.was(.test) == "make test")

        let manual = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        manual.draft.setup = "npm ci"
        #expect(manual.was(.setup) == "./scripts/setup.sh")
        #expect(!manual.isEdited)
    }

    @Test func currentBranchStaysInList() {
        let model = ProjectSettingsModel(project: PipelineTests.project, client: nil)
        #expect(model.branchNames == ["main"])
        #expect(model.isDefault("main"))
    }

    @Test func claudeHints() {
        let defaults = ClaudeSettings()
        #expect(ProjectSettingsModel.claudeHint(.inherit, settings: defaults) == localized("ps.claudeHint.inherit"))
        var changed = defaults
        changed.push = .auto
        #expect(ProjectSettingsModel.claudeHint(.inherit, settings: changed) == nil)
        #expect(ProjectSettingsModel.claudeHint(.manual, settings: changed) == localized("ps.claudeHint.manual"))
        #expect(ProjectSettingsModel.claudeHint(.off, settings: changed) == localized("ps.claudeHint.off"))
    }
}

@MainActor
struct ProjectLifecycleTests {
    @Test func removeDeletesCloneAndForgetsProject() async throws {
        let f = try await WorkspaceTests().fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        f.workspace.add(f.project)
        await f.workspace.waitUntilIdle()
        let clone = f.store.cloneDirectory(for: f.project)
        #expect(FileManager.default.fileExists(atPath: clone.path))
        let mr = try #require(f.workspace.state(f.project).mergeRequests.first)
        await f.workspace.remove(f.project)
        #expect(!FileManager.default.fileExists(atPath: clone.path))
        #expect(f.store.projects.isEmpty)
        #expect(f.workspace.runs[mr.id] == nil)
        #expect(f.store.loadMergeRequests()[f.project.id] == nil)
        let origin = try await f.repo.sh("git --git-dir=\(f.repo.origin.path) rev-parse feature", in: f.repo.root)
        #expect(origin == f.workspace.run(mr).pushedSHA ?? origin)
    }

    @Test func pausedProjectIsSkippedByCheckAll() async throws {
        let f = try await WorkspaceTests().fixture()
        defer {
            f.store.signOut()
            f.repo.remove()
        }
        var paused = f.project
        paused.paused = true
        f.store.projects = [paused]
        f.workspace.checkAll()
        await f.workspace.waitUntilIdle()
        #expect(f.workspace.state(paused).loading == .loading)
        #expect(!FileManager.default.fileExists(atPath: f.store.cloneDirectory(for: paused).path))
    }
}
