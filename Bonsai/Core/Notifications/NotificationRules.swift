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

    private static func isRunning(_ status: MRStatus) -> Bool {
        if case .running = status { true } else { false }
    }
}
