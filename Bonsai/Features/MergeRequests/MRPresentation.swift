import Foundation

struct MRPresentation: Equatable {
    enum Icon: Equatable {
        case spinner, check, cross, down, redo, none
        case claudeSpinner, dots
    }

    enum Tone: Equatable {
        case blue, green, orange, red, secondary, purple
    }

    enum Group: Equatable {
        case decide, working, attention, fine
    }

    enum Action: Equatable, Hashable {
        case run, stop, retry, rerunCI
        case fix, retryFix
        case stopFix, reject, view, revert, terminal, recheck

        var isPrimary: Bool { self == .fix || self == .retryFix || self == .view }
        var hasStar: Bool { self == .fix || self == .retryFix }
    }

    var statusText: String
    var icon: Icon
    var tone: Tone
    var bannerTitle: String
    var bannerBody: String
    var actions: [Action]
    var canFix: Bool
    var group: Group
    var bodyLines = 1

    init(_ run: MRRun) {
        if let fix = run.fix, Self.showsFix(fix, status: run.status) {
            self.init(fix: fix, run: run)
        } else {
            self.init(pipeline: run)
        }
    }

    private init(pipeline run: MRRun) {
        canFix = false
        actions = []
        group = .fine
        defer { group = Self.group(tone: tone, icon: icon) }
        switch run.status {
        case .unknown:
            statusText = ""
            icon = .none
            tone = .secondary
            bannerTitle = ""
            bannerBody = ""
        case .behind(let commits):
            statusText = L("mr.behind", commits)
            icon = .down
            tone = .orange
            bannerTitle = statusText
            bannerBody = L("mr.noteBehind")
            actions = [.run]
        case .running(let stage, let attempt):
            let name = Self.stageName(stage) + "…"
            statusText = attempt > 1 ? "\(name) · \(L("mr.attempt")) \(attempt)" : name
            icon = .spinner
            tone = .blue
            bannerTitle = name
            bannerBody = attempt > 1 ? L("mr.noteRetry", attempt) : Self.subtitle(run[stage])
            actions = [.stop]
        case .upToDate(let pushed):
            statusText = L("mr.fresh")
            icon = .check
            tone = .green
            bannerTitle = statusText
            bannerBody = L(pushed ? "mr.bodyDone" : "mr.bodyFresh")
        case .testsFailed:
            statusText = L("mr.testsFailed")
            icon = .cross
            tone = .red
            bannerTitle = statusText
            bannerBody = L("mr.bodyTests")
            actions = [.retry, .fix]
            canFix = true
        case .ciFailed(let job):
            statusText = L("mr.ciFailed")
            icon = .cross
            tone = .red
            bannerTitle = L("mr.bnCi", job)
            bannerBody = L("mr.bodyCi")
            actions = (run.pipelineID == nil ? [] : [.rerunCI]) + [.fix]
            canFix = true
        case .conflict(let files):
            statusText = L("mr.conflict")
            icon = .cross
            tone = .red
            bannerTitle = L("mr.bnConflict", files.count)
            bannerBody = L("mr.bodyConflict")
            actions = [.fix]
            canFix = true
        case .branchChanged:
            statusText = L("mr.pushRejected")
            icon = .redo
            tone = .orange
            bannerTitle = statusText
            bannerBody = L("mr.bodyPush")
        case .pushFailed(let message):
            statusText = Self.stageName(.push)
            icon = .cross
            tone = .red
            bannerTitle = statusText
            bannerBody = message
            actions = [.retry]
        case .error(let message):
            let stage = run.stages.first { $0.state == .failed }?.kind ?? .rebase
            statusText = Self.stageName(stage)
            icon = .cross
            tone = .red
            bannerTitle = statusText
            bannerBody = message
            actions = [.retry]
        }
    }

    static func showsFix(_ fix: ClaudeFix, status: MRStatus) -> Bool {
        switch fix.phase {
        case .pushed:
            if case .upToDate = status { return true }
            return false
        default:
            return true
        }
    }

    private init(fix: ClaudeFix, run: MRRun) {
        canFix = false
        actions = []
        group = .fine
        switch fix.phase {
        case .fixing:
            statusText = L("fix.claudeFixing")
            icon = .claudeSpinner
            tone = .purple
            bannerTitle = statusText
            bannerBody = fix[.claude].log.last { $0.kind == .claude || $0.kind == .tool }?.text ?? L("fix.bn.starting")
            actions = [.stopFix]
        case .checking:
            let stage = fix.stages.first { $0.state == .running } ?? fix[.retest]
            statusText = Self.stageName(stage.kind) + "…"
            icon = .spinner
            tone = .blue
            bannerTitle = L("fix.bn.checking")
            let subtitle = Self.subtitle(stage)
            bannerBody = subtitle.isEmpty ? Self.stageName(stage.kind) : Self.stageName(stage.kind) + " · " + subtitle
            actions = [.stopFix]
        case .ready:
            statusText = L("fix.waitReview")
            icon = .dots
            tone = .purple
            bannerTitle = statusText
            bannerBody = fix.summary
            bodyLines = 2
            actions = [.reject, .view]
        case .pushing:
            statusText = L("fix.bn.pushing")
            icon = .spinner
            tone = .blue
            bannerTitle = statusText
            bannerBody = Self.subtitle(fix[.push])
        case .ci:
            statusText = L("fix.bn.ci")
            icon = .spinner
            tone = .blue
            bannerTitle = statusText
            bannerBody = L("mr.sub.pipeline")
        case .pushed:
            statusText = L("fix.fixedByClaude")
            icon = .check
            tone = .green
            bannerTitle = L("fix.bn.pushed")
            bannerBody = fix.summary
            bodyLines = 2
            actions = [.revert, .view]
        case .gaveUp:
            statusText = L("fix.claudeGaveUp")
            icon = .cross
            tone = .red
            bannerTitle = statusText
            bannerBody = L("fix.gaveUpBody", fix.attempt)
            actions = [.terminal, .retryFix]
        case .terminal:
            statusText = L("fix.terminalStatus")
            icon = .dots
            tone = .purple
            bannerTitle = statusText
            bannerBody = fix.summary
            bodyLines = 2
            actions = [.recheck]
        case .rejected, .stopped, .reverted:
            let base = MRPresentation(pipeline: run)
            statusText = base.statusText
            icon = base.icon
            tone = base.tone
            bannerTitle = base.bannerTitle
            bannerBody = L(fix.phase == .rejected ? "fix.bn.rejected" : fix.phase == .stopped ? "fix.bn.stopped" : "fix.bn.reverted")
            actions = base.actions
            canFix = base.canFix
        }
        group = Self.group(tone: tone, icon: icon)
    }

    static func group(tone: Tone, icon: Icon) -> Group {
        switch (tone, icon) {
        case (.purple, .dots): .decide
        case (.purple, _), (.blue, _): .working
        case (.red, _): .attention
        default: .fine
        }
    }

    static func stages(_ run: MRRun) -> [Stage] {
        guard let fix = run.fix, showsFix(fix, status: run.status) else { return run.stages }
        let failedIndex = run.stages.firstIndex { $0.state == .failed } ?? (run.stages.count - 1)
        let pre = Array(run.stages.prefix(failedIndex + 1))
        switch fix.phase {
        case .rejected, .stopped, .reverted:
            return run.stages
        default:
            return pre + fix.stages
        }
    }

    static func stageName(_ kind: StageKind) -> String {
        switch kind {
        case .claude: L("fix.stage.claude")
        case .continueRebase: L("mr.stage.rebase")
        case .retest: L("mr.stage.test")
        default: L("mr.stage.\(kind.rawValue)")
        }
    }

    static func subtitle(_ stage: Stage) -> String {
        switch stage.caption {
        case .onto: L("mr.sub.onto", stage.detail)
        case .notNeeded: L("mr.notNeeded")
        case .ciPassed: L("mr.ciPassed")
        case .conflictFiles: L("mr.conflictSub", Int(stage.detail) ?? 0)
        case .pushRejected: L("mr.pushRejectSub")
        case .ciFailed: L("mr.ciFailSub", stage.detail)
        case .command: stage.detail
        case .pipeline: L("mr.sub.pipeline")
        case .none: ""
        case .claudeAttempt:
            numbers(stage.detail).count == 2 ? L("fix.claudeRun", numbers(stage.detail)[0], numbers(stage.detail)[1]) : ""
        case .claudeChanged:
            numbers(stage.detail).count == 3
                ? L("fix.files", numbers(stage.detail)[0]) + " · " + stat(added: numbers(stage.detail)[1], removed: numbers(stage.detail)[2]) : ""
        case .claudeResolved: L("fix.claudeResolved", Int(stage.detail) ?? 0)
        case .claudeFailed: L("fix.claudeFail", Int(stage.detail) ?? 0)
        case .afterFix: L("fix.sub.afterFix", stage.detail)
        }
    }

    static func stat(added: Int, removed: Int) -> String {
        ClaudeStreamParser.stat(added: added, removed: removed).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
    }

    private static func numbers(_ detail: String) -> [Int] {
        detail.split(separator: "/").compactMap { Int($0) }
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.minimumIntegerDigits = 1
        return (formatter.string(from: NSNumber(value: seconds)) ?? "") + " " + L("mr.sec")
    }

    static func text(_ line: LogLine) -> String {
        line.kind == .note ? L("mr.note.\(line.text)") : line.text
    }

    static func displayKind(_ line: LogLine, stageState: StageState) -> LogLine.Kind {
        if line.kind == .output && stageState == .failed && line.text.range(of: #"FAIL|failed|rejected|error|Error|CONFLICT"#, options: .regularExpression) != nil {
            return .error
        }
        return line.kind
    }

    static func autoOpen(_ run: MRRun) -> StageKind? {
        let stages = stages(run)
        if run.fix?.phase == .gaveUp { return .claude }
        if let failed = stages.last(where: { $0.state == .failed }) { return failed.kind }
        return stages.first { $0.state == .running }?.kind
    }

    static func groups(_ items: [(MergeRequest, MRRun)]) -> [(title: String, items: [(MergeRequest, MRRun)])] {
        let titled: [(Group, String)] = [(.decide, L("fix.grpDecide")), (.working, L("mr.grpWorking")),
                                         (.attention, L("mr.grpAttention")), (.fine, L("mr.grpFine"))]
        return titled.map { group, title in (title, items.filter { MRPresentation($0.1).group == group }) }.filter { !$0.1.isEmpty }
    }

    static func subtitle(project: Project, count: Int, checkedAt: Date?, now: Date = Date()) -> String {
        var parts = [project.path, count == 0 ? L("mr.subtitleEmpty") : L("mr.count", count)]
        if count > 0, let checkedAt { parts.append(checked(checkedAt, now: now)) }
        return parts.joined(separator: " · ")
    }

    static func checked(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return L("mr.checkedNow") }
        return L("mr.checkedAgo", relative(date, now: now))
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
