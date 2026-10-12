// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct MainPresentation: Equatable {
    enum Action: Equatable, Hashable {
        case edit, fix, pick, stop, reject

        var isPrimary: Bool { self == .fix || self == .pick }
    }

    static let rowID = "main"

    var statusText: String
    var icon: MRPresentation.Icon
    var tone: MRPresentation.Tone
    var bannerIcon: MRPresentation.Icon
    var bannerTitle: String
    var bannerBody = ""
    var bodyLines = 1
    var actions: [Action] = []
    var group: MRPresentation.Group

    init(_ check: MainCheck, branch: String) {
        let failure = localized(
            check.failedStage == .setup ? "main.bn.failSetup" : "main.bn.failTest", branch)
        switch check.phase {
        case .checking, .passed:
            statusText = localized("main.st.checking")
            icon = .spinner
            tone = .blue
            bannerIcon = .spinner
            bannerTitle = localized("main.bn.checking", branch)
            bannerBody = Self.running(check.stages) ?? localized("fix.bn.starting")
            group = .working
        case .failed, .rejected, .stopped, .missing:
            statusText =
                check.pick
                ? localized("main.st.noCmds")
                : localized(check.failedStage == .setup ? "main.st.setup" : "main.st.test")
            icon = .cross
            tone = .red
            bannerIcon = .cross
            bannerTitle = check.pick ? localized("main.st.noCmds") : failure
            switch check.phase {
            case .rejected: bannerBody = localized("main.bn.rejected")
            case .stopped: bannerBody = localized("main.bn.stopped")
            case .failed: bannerBody = check.pick ? "" : localized("main.bn.failBody")
            default: bannerBody = ""
            }
            actions = [.edit, check.pick ? .pick : .fix]
            group = .attention
        case .fixing:
            let claudeKind: StageKind = check.pick ? .pick : .claude
            if check.proposal?[claudeKind].state == .running {
                statusText = localized(check.pick ? "main.st.picking" : "main.st.fixing")
                icon = .claudeSpinner
                tone = .purple
                bannerIcon = .claudeSpinner
                bannerTitle = localized(check.pick ? "main.bn.picking" : "main.bn.fixing")
                bannerBody =
                    check.proposal?[claudeKind].log.last { $0.kind == .claude || $0.kind == .tool }?.text
                    ?? localized("fix.bn.starting")
            } else {
                statusText = localized("main.st.checking")
                icon = .spinner
                tone = .blue
                bannerIcon = .spinner
                bannerTitle = localized("main.bn.checking", branch)
                bannerBody = Self.running(check.proposal?.stages ?? []) ?? localized("fix.bn.starting")
            }
            actions = [.stop]
            group = .working
        case .ready:
            statusText = localized(check.pick ? "main.st.picked" : "main.st.ready")
            icon = .dots
            tone = .purple
            bannerIcon = .star
            bannerTitle = statusText
            bannerBody = check.proposal?.summary ?? ""
            bodyLines = 2
            actions = [.reject]
            group = .decide
        case .broken:
            statusText = localized("main.st.broken")
            icon = .brokenCross
            tone = .orange
            bannerIcon = .brokenCross
            bannerTitle = failure
            bannerBody = localized("main.bn.brokenBody", branch)
            group = .attention
        }
    }

    static func isVisible(_ check: MainCheck?) -> Bool {
        guard let check else { return false }
        return check.phase != .passed
    }

    static func stages(_ check: MainCheck) -> [Stage] {
        guard let proposal = check.proposal else { return check.stages }
        let before = check.pick ? check.stages.filter { $0.kind == .ci || $0.kind == .checkout } : check.stages
        return before + proposal.stages
    }

    static func autoOpen(_ check: MainCheck) -> Int? {
        let stages = stages(check)
        return stages.lastIndex { $0.state == .running }
            ?? stages.lastIndex { $0.state == .failed && $0.kind != .ci }
    }

    static func commandsLine(_ commands: MainCheck.Commands) -> String {
        [commands.setup, commands.test].map(MainPipeline.oneLine).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func running(_ stages: [Stage]) -> String? {
        guard let stage = stages.first(where: { $0.state == .running }) else { return nil }
        let subtitle = MRPresentation.subtitle(stage)
        let name = MRPresentation.stageName(stage.kind)
        return subtitle.isEmpty ? name : name + " · " + subtitle
    }
}
