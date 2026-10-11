// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Observation

@MainActor
@Observable
final class Scheduler {
    let workspace: Workspace
    private(set) var nextCheck: Date?
    private var timer: Task<Void, Never>?
    private let clock: @Sendable () -> Date

    init(workspace: Workspace, clock: @escaping @Sendable () -> Date = Date.init) {
        self.workspace = workspace
        self.clock = clock
    }

    var pausedUntil: Date? {
        get { workspace.store.pausedUntil.flatMap { $0 > clock() ? $0 : nil } }
        set { workspace.store.pausedUntil = newValue }
    }

    var isPaused: Bool { pausedUntil != nil }

    func start() {
        if !isPaused { workspace.checkAll() }
        reschedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        nextCheck = nil
    }

    func reschedule() {
        timer?.cancel()
        guard let seconds = workspace.store.settings.interval.seconds else {
            nextCheck = nil
            timer = nil
            return
        }
        nextCheck = clock().addingTimeInterval(seconds)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !Task.isCancelled else { return }
                self.nextCheck = self.clock().addingTimeInterval(seconds)
                if !self.isPaused { self.workspace.checkAll() }
            }
        }
    }

    func checkNow() {
        workspace.checkAll()
        reschedule()
    }

    func pauseForHour() {
        pausedUntil = clock().addingTimeInterval(3600)
    }

    func resume() {
        pausedUntil = nil
        workspace.checkAll()
        reschedule()
    }
}
