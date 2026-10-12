// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import AppKit
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let app: AppModel
    private let center = UNUserNotificationCenter.current()
    private var wasConnected = true

    init(app: AppModel) {
        self.app = app
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        app.onStatusChange.append { [weak self] change in self?.handle(change) }
        app.onMainChange.append { [weak self] change in self?.handle(change) }
        observeConnection()
    }

    private var settings: NotificationSettings { app.store.settings.notifications }

    private var quiet: Bool { settings.quietWhileWindowOpen && app.isMainWindowVisible && NSApp.isActive }

    func handle(_ change: Workspace.StatusChange) {
        guard let note = NotificationRules.note(for: change, settings: settings), !quiet else { return }
        post(
            title: localized(note.title), body: "\(change.mr.title) · \(change.project.name)",
            info: ["project": note.projectID, "mr": note.mrID], id: "\(note.mrID)-\(note.title)")
    }

    func handle(_ change: Workspace.MainChange) {
        guard let title = NotificationRules.mainNote(for: change, settings: settings), !quiet else { return }
        post(
            title: title, body: NotificationRules.mainBody(for: change),
            info: ["project": change.project.id, "mr": MainPresentation.rowID], id: "\(change.project.id)-main")
    }

    private func observeConnection() {
        let lost = withObservationTracking {
            app.workspace.connectionLost
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeConnection() }
        }
        if lost && wasConnected && settings.noConnection && !quiet {
            post(
                title: localized("notify.noConnection"), body: app.store.account?.server.host() ?? "", info: [:],
                id: "connection")
        }
        wasConnected = !lost
    }

    private func post(title: String, body: String, info: [String: Any], id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = info
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let project = info["project"] as? Int
        let mr = info["mr"] as? String
        await MainActor.run { app.showMain(project: project, mr: mr) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}
