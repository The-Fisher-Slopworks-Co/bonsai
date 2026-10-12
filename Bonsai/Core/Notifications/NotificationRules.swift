// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

enum NotificationRules {
    struct Note: Equatable {
        var title: String
        var mrID: String
        var projectID: Int
    }

    static func note(for change: Workspace.StatusChange, settings: NotificationSettings) -> Note? {
        if change.newFix != change.oldFix, let phase = change.newFix {
            let fixKey: String? =
                switch phase {
                case .ready: settings.claudeReady ? "notify.claudeReady" : nil
                case .gaveUp: settings.needsMe ? "notify.claudeFailed" : nil
                case .pushed:
                    change.old != change.new && change.new == .upToDate(pushed: true) && settings.updated
                        ? "notify.ok" : nil
                default: nil
                }
            if let fixKey { return Note(title: fixKey, mrID: change.mr.id, projectID: change.project.id) }
            return nil
        }
        let key: String?
        switch change.new {
        case .upToDate(pushed: true):
            key = isRunning(change.old) && settings.updated ? "notify.ok" : nil
        case .testsFailed:
            key = settings.needsMe ? "notify.testsFailed" : nil
        case .ciFailed:
            key = settings.needsMe ? "notify.ciFailed" : nil
        case .conflict:
            key = settings.needsMe ? "notify.conflict" : nil
        case .running(.rebase, attempt: 1):
            key = settings.started && !isRunning(change.old) ? "notify.started" : nil
        default:
            key = nil
        }
        guard let key, change.old != change.new else { return nil }
        return Note(title: key, mrID: change.mr.id, projectID: change.project.id)
    }

    static func mainNote(for change: Workspace.MainChange, settings: NotificationSettings) -> String? {
        let blocking: Set<MainCheck.Phase> = [.failed, .broken, .missing]
        guard settings.needsMe, blocking.contains(change.new.phase) else { return nil }
        if let old = change.old, blocking.contains(old) { return nil }
        if change.new.pick { return localized("main.st.noCmds") }
        let key = change.new.failedStage == .setup ? "main.bn.failSetup" : "main.bn.failTest"
        return localized(key, change.project.targetBranch)
    }

    static func mainBody(for change: Workspace.MainChange) -> String {
        guard change.mergeRequests > 0 else { return change.project.name }
        return change.project.name + " · " + localized("main.notifyWaiting", change.mergeRequests)
    }

    private static func isRunning(_ status: MRStatus) -> Bool {
        if case .running = status { true } else { false }
    }
}
