import Foundation
import Observation

@MainActor
@Observable
final class ProjectSettingsModel {
    let original: Project
    var draft: Project
    private(set) var branches: [GitLabBranch] = []
    private let client: GitLabClient?

    init(project: Project, client: GitLabClient?) {
        original = project
        draft = project
        self.client = client
    }

    var hasChanges: Bool { draft != original }

    var canSave: Bool {
        hasChanges && !draft.test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        project.rules = project.rules.trimmingCharacters(in: .whitespacesAndNewlines)
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
