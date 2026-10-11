import Foundation
import Testing

@testable import Bonsai

struct NotificationRulesTests {
    let project = PipelineTests.project
    let mr = PipelineTests.mr

    func change(_ old: MRStatus, _ new: MRStatus) -> Workspace.StatusChange {
        Workspace.StatusChange(mr: mr, project: project, old: old, new: new)
    }

    @Test func updatedOnlyAfterOwnRun() {
        let on = NotificationSettings()
        #expect(
            NotificationRules.note(for: change(.running(.ci, attempt: 1), .upToDate(pushed: true)), settings: on)?.title
                == "notify.ok")
        #expect(
            NotificationRules.note(for: change(.running(.ci, attempt: 1), .upToDate(pushed: false)), settings: on)
                == nil)
        #expect(NotificationRules.note(for: change(.unknown, .upToDate(pushed: true)), settings: on) == nil)
        var off = on
        off.updated = false
        #expect(
            NotificationRules.note(for: change(.running(.ci, attempt: 1), .upToDate(pushed: true)), settings: off)
                == nil)
    }

    @Test func failuresNeedMe() {
        var settings = NotificationSettings()
        #expect(
            NotificationRules.note(for: change(.running(.test, attempt: 1), .testsFailed), settings: settings)?.title
                == "notify.testsFailed")
        #expect(
            NotificationRules.note(for: change(.running(.ci, attempt: 1), .ciFailed(job: "lint")), settings: settings)?
                .title == "notify.ciFailed")
        #expect(
            NotificationRules.note(
                for: change(.running(.rebase, attempt: 1), .conflict(files: ["a"])), settings: settings)?.title
                == "notify.conflict")
        #expect(NotificationRules.note(for: change(.testsFailed, .testsFailed), settings: settings) == nil)
        settings.needsMe = false
        #expect(
            NotificationRules.note(for: change(.running(.test, attempt: 1), .testsFailed), settings: settings) == nil)
    }

    @Test func startedIsOffByDefault() {
        var settings = NotificationSettings()
        #expect(
            NotificationRules.note(for: change(.behind(commits: 2), .running(.rebase, attempt: 1)), settings: settings)
                == nil)
        settings.started = true
        let note = NotificationRules.note(
            for: change(.behind(commits: 2), .running(.rebase, attempt: 1)), settings: settings)
        #expect(note == NotificationRules.Note(title: "notify.started", mrID: mr.id, projectID: project.id))
        #expect(
            NotificationRules.note(
                for: change(.running(.ci, attempt: 1), .running(.rebase, attempt: 1)), settings: settings) == nil)
    }
}

struct MenuBarModelTests {
    func mr(_ iid: Int) -> MergeRequest {
        var mr = PipelineTests.mr
        mr.iid = iid
        mr.title = "MR \(iid)"
        return mr
    }

    func run(_ status: MRStatus) -> MRRun {
        var run = MRRun()
        run.status = status
        return run
    }

    @Test func sectionsAndFreshLine() {
        let model = MenuBarModel(
            items: [
                (mr(1), run(.running(.test, attempt: 1))), (mr(2), run(.testsFailed)),
                (mr(3), run(.upToDate(pushed: true))),
                (mr(4), run(.upToDate(pushed: false))), (mr(5), run(.conflict(files: ["a"]))),
            ],
            isChecking: false, lastCheck: Date(), pausedUntil: nil)
        #expect(model.sections.map(\.title) == [localized("menu.inProgress"), localized("menu.attention")])
        #expect(model.sections[0].items.map(\.iid) == [1])
        #expect(model.sections[1].items.map(\.iid) == [2, 5])
        #expect(model.freshCount == 2)
        #expect(model.hasProblems)
        #expect(model.isWorking)
        #expect(model.headerText == localized("menu.checkedNow"))
    }

    @Test func calmMenu() {
        let model = MenuBarModel(
            items: [(mr(1), run(.upToDate(pushed: false)))], isChecking: true, lastCheck: nil, pausedUntil: nil)
        #expect(model.sections.isEmpty)
        #expect(!model.hasProblems)
        #expect(!model.isWorking)
        #expect(model.header == .checking)
        #expect(model.headerText == localized("menu.checking"))
    }

    @Test func pausedHeader() {
        let until = Date().addingTimeInterval(3600)
        let model = MenuBarModel(items: [], isChecking: true, lastCheck: nil, pausedUntil: until)
        #expect(model.header == .paused(until: until))
        #expect(model.isPaused)
        #expect(model.headerText.contains(until.formatted(date: .omitted, time: .shortened)))
    }

    @Test func freshPlural() throws {
        let path = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj"))
        let ru = try #require(Bundle(path: path))
        #expect(localized("menu.fresh", bundle: ru, [1]) == "Ещё 1 MR актуален")
        #expect(localized("menu.fresh", bundle: ru, [3]) == "Ещё 3 MR актуальны")
    }
}
