// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

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
            statusText = localized("mr.behind", commits)
            icon = .down
            tone = .orange
            bannerTitle = statusText
            bannerBody = localized("mr.noteBehind")
            actions = [.run]
        case .running(let stage, let attempt):
            let name = Self.stageName(stage) + "…"
            statusText = attempt > 1 ? "\(name) · \(localized("mr.attempt")) \(attempt)" : name
            icon = .spinner
            tone = .blue
            bannerTitle = name
            bannerBody = attempt > 1 ? localized("mr.noteRetry", attempt) : Self.subtitle(run[stage])
            actions = [.stop]
        case .upToDate(let pushed):
            statusText = localized("mr.fresh")
            icon = .check
            tone = .green
            bannerTitle = statusText
            bannerBody = localized(pushed ? "mr.bodyDone" : "mr.bodyFresh")
        case .testsFailed:
            statusText = localized("mr.testsFailed")
            icon = .cross
            tone = .red
            bannerTitle = statusText
            bannerBody = localized("mr.bodyTests")
            actions = [.retry, .fix]
            canFix = true
        case .ciFailed(let job):
            statusText = localized("mr.ciFailed")
            icon = .cross
            tone = .red
            bannerTitle = localized("mr.bnCi", job)
            bannerBody = localized("mr.bodyCi")
            actions = (run.pipelineID == nil ? [] : [.rerunCI]) + [.fix]
            canFix = true
        case .conflict(let files):
            statusText = localized("mr.conflict")
            icon = .cross
            tone = .red
            bannerTitle = localized("mr.bnConflict", files.count)
            bannerBody = localized("mr.bodyConflict")
            actions = [.fix]
            canFix = true
        case .branchChanged:
            statusText = localized("mr.pushRejected")
            icon = .redo
            tone = .orange
            bannerTitle = statusText
            bannerBody = localized("mr.bodyPush")
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
            statusText = localized("fix.claudeFixing")
            icon = .claudeSpinner
            tone = .purple
            bannerTitle = statusText
            bannerBody =
                fix[.claude].log.last { $0.kind == .claude || $0.kind == .tool }?.text ?? localized("fix.bn.starting")
            actions = [.stopFix]
        case .checking:
            let stage = fix.stages.first { $0.state == .running } ?? fix[.retest]
            statusText = Self.stageName(stage.kind) + "…"
            icon = .spinner
            tone = .blue
            bannerTitle = localized("fix.bn.checking")
            let subtitle = Self.subtitle(stage)
            bannerBody = subtitle.isEmpty ? Self.stageName(stage.kind) : Self.stageName(stage.kind) + " · " + subtitle
            actions = [.stopFix]
        case .ready:
            statusText = localized("fix.waitReview")
            icon = .dots
            tone = .purple
            bannerTitle = statusText
            bannerBody = fix.summary
            bodyLines = 2
            actions = [.reject, .view]
        case .pushing:
            statusText = localized("fix.bn.pushing")
            icon = .spinner
            tone = .blue
            bannerTitle = statusText
            bannerBody = Self.subtitle(fix[.push])
        case .ci:
            statusText = localized("fix.bn.ci")
            icon = .spinner
            tone = .blue
            bannerTitle = statusText
            bannerBody = localized("mr.sub.pipeline")
        case .pushed:
            statusText = localized("fix.fixedByClaude")
            icon = .check
            tone = .green
            bannerTitle = localized("fix.bn.pushed")
            bannerBody = fix.summary
            bodyLines = 2
            actions = [.revert, .view]
        case .gaveUp:
            statusText = localized("fix.claudeGaveUp")
            icon = .cross
            tone = .red
            bannerTitle = statusText
            bannerBody = localized("fix.gaveUpBody", fix.attempt)
            actions = [.terminal, .retryFix]
        case .terminal:
            statusText = localized("fix.terminalStatus")
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
            bannerBody = localized(
                fix.phase == .rejected
                    ? "fix.bn.rejected" : fix.phase == .stopped ? "fix.bn.stopped" : "fix.bn.reverted")
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
        case .claude: localized("fix.stage.claude")
        case .continueRebase: localized("mr.stage.rebase")
        case .retest: localized("mr.stage.test")
        default: localized("mr.stage.\(kind.rawValue)")
        }
    }

    static func subtitle(_ stage: Stage) -> String {
        switch stage.caption {
        case .onto: localized("mr.sub.onto", stage.detail)
        case .notNeeded: localized("mr.notNeeded")
        case .ciPassed: localized("mr.ciPassed")
        case .conflictFiles: localized("mr.conflictSub", Int(stage.detail) ?? 0)
        case .pushRejected: localized("mr.pushRejectSub")
        case .ciFailed: localized("mr.ciFailSub", stage.detail)
        case .command: stage.detail
        case .pipeline: localized("mr.sub.pipeline")
        case .none: ""
        case .claudeAttempt:
            numbers(stage.detail).count == 2
                ? localized("fix.claudeRun", numbers(stage.detail)[0], numbers(stage.detail)[1]) : ""
        case .claudeChanged:
            numbers(stage.detail).count == 3
                ? localized("fix.files", numbers(stage.detail)[0]) + " · "
                    + stat(added: numbers(stage.detail)[1], removed: numbers(stage.detail)[2]) : ""
        case .claudeResolved: localized("fix.claudeResolved", Int(stage.detail) ?? 0)
        case .claudeFailed: localized("fix.claudeFail", Int(stage.detail) ?? 0)
        case .afterFix: localized("fix.sub.afterFix", stage.detail)
        case .ref: stage.detail
        case .mainCiPassed: localized("main.sub.ciOk")
        case .mainCiFailed: localized("main.sub.ciFail")
        case .commandsOnly: localized("main.sub.commandsOnly")
        case .commandsChanged: commandsChanged(numbers(stage.detail))
        }
    }

    private static func commandsChanged(_ numbers: [Int]) -> String {
        guard numbers.count == 3 else { return "" }
        if numbers[0] == 1 && numbers[1] == 1 { return localized("main.sub.both") }
        let name = localized(numbers[0] == 1 ? "main.sub.setup" : "main.sub.test")
        return numbers[2] > 0 ? name + " · " + localized("main.sub.lines", numbers[2]) : name
    }

    static func stat(added: Int, removed: Int) -> String {
        ClaudeStreamParser.stat(added: added, removed: removed).trimmingCharacters(
            in: CharacterSet(charactersIn: " ()"))
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
        return (formatter.string(from: NSNumber(value: seconds)) ?? "") + " " + localized("mr.sec")
    }

    static func text(_ line: LogLine) -> String {
        line.kind == .note ? localized("mr.note.\(line.text)") : line.text
    }

    static func displayKind(_ line: LogLine, stageState: StageState) -> LogLine.Kind {
        if line.kind == .output && stageState == .failed
            && line.text.range(of: #"FAIL|failed|rejected|error|Error|CONFLICT"#, options: .regularExpression) != nil
        {
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
        let titled: [(Group, String)] = [
            (.decide, localized("fix.grpDecide")), (.working, localized("mr.grpWorking")),
            (.attention, localized("mr.grpAttention")), (.fine, localized("mr.grpFine")),
        ]
        return titled.map { group, title in (title, items.filter { MRPresentation($0.1).group == group }) }.filter {
            !$0.1.isEmpty
        }
    }

    static func subtitle(project: Project, count: Int, checkedAt: Date?, now: Date = Date()) -> String {
        var parts = [project.path, count == 0 ? localized("mr.subtitleEmpty") : localized("mr.count", count)]
        if count > 0, let checkedAt { parts.append(checked(checkedAt, now: now)) }
        return parts.joined(separator: " · ")
    }

    static func checked(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return localized("mr.checkedNow") }
        return localized("mr.checkedAgo", relative(date, now: now))
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
