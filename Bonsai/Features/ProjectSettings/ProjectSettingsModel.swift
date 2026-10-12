// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Observation

@MainActor
@Observable
final class ProjectSettingsModel {
    enum Command { case environment, setup, test }

    let original: Project
    var draft: Project
    let proposal: MainCheck.Proposal?
    private(set) var branches: [GitLabBranch] = []
    private let client: GitLabClient?

    init(project: Project, client: GitLabClient?, proposal: MainCheck.Proposal? = nil) {
        original = project
        draft = project
        self.proposal = proposal
        self.client = client
        if let commands = proposal?.commands {
            draft.setup = commands.setup
            draft.test = commands.test
        }
    }

    var isEdited: Bool {
        guard let proposed = proposal?.commands else { return false }
        return MainCheck.Commands(draft) != proposed
    }

    func was(_ command: Command) -> String? {
        let old = MainPipeline.oneLine(value(command, in: original))
        guard !old.isEmpty, MainPipeline.oneLine(value(command, in: draft)) != old else { return nil }
        return old
    }

    private func value(_ command: Command, in project: Project) -> String {
        switch command {
        case .environment: project.environment
        case .setup: project.setup
        case .test: project.test
        }
    }

    var hasChanges: Bool { draft != original }

    var canSave: Bool {
        hasChanges && !draft.test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && copiedAreRelative
    }

    var copiedAreRelative: Bool {
        draft.copiedPaths.allSatisfy { path in
            let parts = path.split(separator: "/").filter { $0 != "." }
            return !path.hasPrefix("/") && !path.hasPrefix("~") && parts.first.map { $0 != ".git" } == true
                && !parts.contains("..")
        }
    }

    var branchNames: [String] {
        let names = branches.map(\.name)
        return names.contains(draft.targetBranch) ? names : [draft.targetBranch] + names
    }

    func isDefault(_ name: String) -> Bool {
        branches.first { $0.name == name }?.isDefault ?? (name == original.defaultBranch)
    }

    func load() async {
        guard let client else { return }
        branches = (try? await client.branches(project: original.id, defaultBranch: original.defaultBranch)) ?? []
    }

    func saved() -> Project {
        var project = draft
        project.setup = project.setup.trimmingCharacters(in: .whitespacesAndNewlines)
        project.test = project.test.trimmingCharacters(in: .whitespacesAndNewlines)
        project.environment = project.environment.trimmingCharacters(in: .whitespacesAndNewlines)
        project.rules = project.rules.trimmingCharacters(in: .whitespacesAndNewlines)
        project.localCopy = project.localCopy.trimmingCharacters(in: .whitespacesAndNewlines)
        project.copied = project.copiedPaths.joined(separator: "\n")
        return project
    }

    static func claudeHint(_ mode: ClaudeMode, settings: ClaudeSettings) -> String? {
        switch mode {
        case .inherit:
            let described = settings.onTests && settings.onCI && !settings.onConflict && settings.push == .review
            return described ? localized("ps.claudeHint.inherit") : nil
        case .manual:
            return localized("ps.claudeHint.manual")
        case .off:
            return localized("ps.claudeHint.off")
        }
    }
}
