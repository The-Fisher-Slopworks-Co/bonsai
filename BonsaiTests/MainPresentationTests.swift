// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation
import Testing

@testable import Bonsai

struct MainPresentationTests {
    static func check(_ phase: MainCheck.Phase, failed: StageKind? = .test, pick: Bool = false) -> MainCheck {
        var check = MainCheck(
            phase: phase, sha: "3f9c2e1aa", commands: MainCheck.Commands(setup: "./setup.sh", test: "make test"),
            pick: pick)
        check.stages = [
            Stage(kind: .ci, state: .done, caption: .mainCiPassed), Stage(kind: .checkout, state: .done),
            Stage(kind: .setup, state: failed == .setup ? .failed : .done),
            Stage(kind: .test, state: failed == .test ? .failed : failed == .setup ? .pending : .done),
        ]
        return check
    }

    @Test func failedOffersEditAndFix() {
        let p = MainPresentation(Self.check(.failed), branch: "main")
        #expect(p.statusText == localized("main.st.test"))
        #expect(p.bannerTitle == localized("main.bn.failTest", "main"))
        #expect(p.bannerBody == localized("main.bn.failBody"))
        #expect(p.actions == [.edit, .fix])
        #expect(p.group == .attention)
        #expect(p.icon == .cross)

        let setup = MainPresentation(Self.check(.stopped, failed: .setup), branch: "main")
        #expect(setup.bannerTitle == localized("main.bn.failSetup", "main"))
        #expect(setup.bannerBody == localized("main.bn.stopped"))
    }

    @Test func missingCommandsOfferPick() {
        let p = MainPresentation(Self.check(.missing, failed: nil, pick: true), branch: "main")
        #expect(p.bannerTitle == localized("main.st.noCmds"))
        #expect(p.actions == [.edit, .pick])
    }

    @Test func claudeThenVerification() {
        var check = Self.check(.fixing, failed: nil, pick: true)
        check.proposal = MainCheck.Proposal(
            stages: [
                Stage(kind: .pick, state: .running, log: [LogLine(text: "Read  Makefile", kind: .tool)]),
                Stage(kind: .setup), Stage(kind: .test),
            ])
        let claude = MainPresentation(check, branch: "main")
        #expect(claude.bannerTitle == localized("main.bn.picking"))
        #expect(claude.bannerBody == "Read  Makefile")
        #expect(claude.icon == .claudeSpinner)
        #expect(claude.actions == [.stop])
        #expect(MainPresentation.stages(check).map(\.kind) == [.ci, .checkout, .pick, .setup, .test])
        #expect(MainPresentation.autoOpen(check) == 2)

        check.proposal?[.pick].state = .done
        check.proposal?[.setup] = Stage(kind: .setup, state: .running, caption: .command, detail: "make deps")
        let verifying = MainPresentation(check, branch: "main")
        #expect(verifying.bannerTitle == localized("main.bn.checking", "main"))
        #expect(verifying.bannerBody == localized("mr.stage.setup") + " · make deps")
        #expect(verifying.group == .working)
    }

    @Test func readyShowsSummaryAndBrokenWaits() {
        var check = Self.check(.ready, failed: .test)
        check.proposal = MainCheck.Proposal(stages: [], summary: "Тестам нужен Postgres.")
        let ready = MainPresentation(check, branch: "main")
        #expect(ready.bannerIcon == .star)
        #expect(ready.bannerBody == "Тестам нужен Postgres.")
        #expect(ready.group == .decide)
        #expect(ready.actions == [.reject, .view])

        let broken = MainPresentation(Self.check(.broken), branch: "master")
        #expect(broken.icon == .brokenCross)
        #expect(broken.tone == .orange)
        #expect(broken.bannerBody == localized("main.bn.brokenBody", "master"))
        #expect(broken.actions.isEmpty)
    }

    @Test func rowHidesOncePassed() {
        #expect(!MainPresentation.isVisible(nil))
        #expect(!MainPresentation.isVisible(Self.check(.passed, failed: nil)))
        #expect(MainPresentation.isVisible(Self.check(.checking, failed: nil)))
        #expect(MainPresentation.commandsLine(Self.check(.failed).commands) == "./setup.sh · make test")
    }

    @Test func waitingMergeRequests() {
        var run = MRRun()
        run.status = .testsFailed
        let waiting = MRPresentation(run, waitingOn: "main")
        #expect(waiting.group == .waiting)
        #expect(waiting.icon == .pause)
        #expect(waiting.statusText.isEmpty)
        #expect(waiting.bannerTitle == localized("main.bn.waitTitle", "main"))
        #expect(waiting.actions.isEmpty)
        #expect(MRPresentation.stages(run, waitingOn: "main").allSatisfy { $0.state == .pending })

        let mr = MergeRequest(
            projectID: 1, iid: 1, title: "A", author: "me", sourceBranch: "a", targetBranch: "main",
            webURL: URL(string: "https://x")!, sha: "s", draft: false, labels: [])
        let groups = MRPresentation.groups([(mr, run)], waitingOn: "main", main: .attention)
        #expect(groups.map(\.title) == [localized("mr.grpAttention"), localized("main.grpWaiting", "main")])
        #expect(groups.map(\.main) == [true, false])

        let subtitle = MRPresentation.subtitle(
            project: PipelineTests.project, count: 5, checkedAt: Date(), waiting: true)
        #expect(subtitle == "g/project-main · \(localized("mr.count", 5)) · \(localized("main.waiting", "main"))")
    }
}
