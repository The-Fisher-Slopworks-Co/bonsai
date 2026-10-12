// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import AppKit
import Foundation
import Testing

@testable import Bonsai

@MainActor
struct StatusItemTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonsai-menu-\(UUID().uuidString)")
    let keychain = Keychain(service: "dev.txssu.Bonsai.tests.\(UUID().uuidString)")

    @Test func menuListsProblemsAndFooter() throws {
        let store = Store(directory: dir, keychain: keychain)
        let project = PipelineTests.project
        store.projects = [project]
        var failing = PipelineTests.mr
        failing.iid = 104
        failing.title = "Новый формат экспорта CSV"
        var fine = PipelineTests.mr
        fine.iid = 102
        store.saveMergeRequests([project.id: [failing, fine]])
        var failed = MRRun()
        failed.status = .testsFailed
        var ok = MRRun()
        ok.status = .upToDate(pushed: false)
        store.saveRuns([failing.id: failed, fine.id: ok])
        store.saveMainChecks([
            project.id: MainCheck(phase: .passed, sha: "base1", commands: MainCheck.Commands(project))
        ])

        let app = AppModel(store: store)
        let controller = StatusItemController(app: app)
        controller.menuNeedsUpdate(controller.menu)
        let titles = controller.menu.items.map(\.title)
        #expect(titles.contains(localized("menu.attention")))
        #expect(titles.contains { $0.hasPrefix("Новый формат экспорта CSV") })
        #expect(titles.contains(localized("menu.fresh", 1)))
        #expect(
            Array(titles.suffix(4)) == [
                localized("menu.open"), localized("menu.pause"), localized("menu.settings"), localized("menu.quit"),
            ])
        #expect(controller.menu.items.last?.keyEquivalent == "q")
        #expect(controller.isDotShown)

        app.scheduler.pauseForHour()
        controller.menuNeedsUpdate(controller.menu)
        #expect(controller.menu.items.map(\.title).contains(localized("menu.resume")))
    }
}
