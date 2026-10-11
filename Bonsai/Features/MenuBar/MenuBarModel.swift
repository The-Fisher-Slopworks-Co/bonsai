import Foundation

struct MenuBarModel: Equatable {
    enum Header: Equatable {
        case paused(until: Date)
        case checking
        case checked(Date?)
    }

    struct Item: Equatable {
        var mrID: String
        var projectID: Int
        var iid: Int
        var title: String
        var status: String
        var icon: MRPresentation.Icon
        var tone: MRPresentation.Tone
    }

    struct Section: Equatable {
        var title: String
        var items: [Item]
    }

    var header: Header
    var sections: [Section]
    var freshCount: Int
    var hasProblems: Bool
    var isWorking: Bool
    var isPaused: Bool

    init(items: [(MergeRequest, MRRun)], isChecking: Bool, lastCheck: Date?, pausedUntil: Date?) {
        if let pausedUntil {
            header = .paused(until: pausedUntil)
        } else if isChecking {
            header = .checking
        } else {
            header = .checked(lastCheck)
        }
        isPaused = pausedUntil != nil
        func item(_ mr: MergeRequest, _ run: MRRun) -> Item {
            let presentation = MRPresentation(run)
            return Item(
                mrID: mr.id, projectID: mr.projectID, iid: mr.iid, title: mr.title, status: presentation.statusText,
                icon: presentation.icon, tone: presentation.tone)
        }
        func members(_ group: MRPresentation.Group) -> [Item] {
            items.filter { MRPresentation($0.1).group == group }.map(item)
        }
        let decide = members(.decide)
        let working = members(.working)
        let attention = members(.attention)
        sections = [
            Section(title: L("menu.awaitingReview"), items: decide),
            Section(title: L("menu.inProgress"), items: working),
            Section(title: L("menu.attention"), items: attention),
        ]
        .filter { !$0.items.isEmpty }
        freshCount =
            items.filter { item in
                guard MRPresentation(item.1).group == .fine else { return false }
                if case .upToDate = item.1.status { return true }
                return false
            }.count
        hasProblems = !attention.isEmpty
        isWorking = !working.isEmpty
    }

    var headerText: String {
        switch header {
        case .paused(let until):
            L("menu.pausedUntil", until.formatted(date: .omitted, time: .shortened))
        case .checking:
            L("menu.checking")
        case .checked(let date):
            if let date, Date().timeIntervalSince(date) >= 60 {
                L("menu.checkedAgo", MRPresentation.relative(date))
            } else {
                L("menu.checkedNow")
            }
        }
    }
}
