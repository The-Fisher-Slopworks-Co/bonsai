// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct ProjectDetail: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    @Binding var selection: String?
    let onEdit: () -> Void

    var body: some View {
        let state = workspace.state(project)
        let check = workspace.mainCheck(project).flatMap { MainPresentation.isVisible($0) ? $0 : nil }
        let waiting = workspace.isWaiting(project) ? project.targetBranch : nil
        Group {
            if state.loading == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: localized("projects.loading")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.mergeRequests.isEmpty && check == nil {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: localized("mr.noMrsTitle"))
                    } icon: {
                        Image("ProjectGlyph").resizable().frame(width: 48, height: 48)
                    }
                } description: {
                    if let minutes = workspace.store.settings.interval.seconds.map({ Int($0 / 60) }) {
                        Text(verbatim: localized("mr.noMrsBody", minutes))
                    }
                }
            } else {
                let items = state.mergeRequests.map { ($0, workspace.run($0)) }
                HStack(spacing: 0) {
                    MRList(items: items, project: project, main: check, waitingOn: waiting, selection: $selection)
                        .frame(width: 340)
                    Divider()
                    if let check, selection == MainPresentation.rowID {
                        MainDetail(project: project, check: check, onEdit: onEdit)
                            .id(MainPresentation.rowID)
                    } else if let mr = state.mergeRequests.first(where: { $0.id == selection }) {
                        MRDetail(mr: mr, run: workspace.run(mr), waitingOn: waiting)
                            .id(mr.id)
                    } else {
                        Color.clear
                    }
                }
                .onAppear { selectFirstIfNeeded(items, main: check, waitingOn: waiting) }
                .onChange(of: state.mergeRequests.map(\.id)) {
                    selectFirstIfNeeded(items, main: check, waitingOn: waiting)
                }
                .onChange(of: check == nil) { selectFirstIfNeeded(items, main: check, waitingOn: waiting) }
            }
        }
    }

    private func selectFirstIfNeeded(_ items: [(MergeRequest, MRRun)], main: MainCheck?, waitingOn: String?) {
        let mainSelected = selection == MainPresentation.rowID && main != nil
        guard selection == nil || !(mainSelected || items.contains(where: { $0.0.id == selection })) else { return }
        let group = main.map { MainPresentation($0, branch: project.targetBranch).group }
        let first = MRPresentation.groups(items, waitingOn: waitingOn, main: group).first
        selection = first?.main == true ? MainPresentation.rowID : first?.items.first?.0.id
    }
}

struct MRList: View {
    let items: [(MergeRequest, MRRun)]
    let project: Project
    let main: MainCheck?
    let waitingOn: String?
    @Binding var selection: String?

    var body: some View {
        let presentation = main.map { MainPresentation($0, branch: project.targetBranch) }
        List(selection: $selection) {
            ForEach(MRPresentation.groups(items, waitingOn: waitingOn, main: presentation?.group), id: \.title) {
                group in
                Section(group.title) {
                    if group.main, let main, let presentation {
                        MainRow(check: main, branch: project.targetBranch, presentation: presentation)
                            .tag(MainPresentation.rowID)
                    }
                    ForEach(group.items, id: \.0.id) { mr, run in
                        MRRow(mr: mr, presentation: MRPresentation(run, waitingOn: waitingOn))
                            .tag(mr.id)
                    }
                }
            }
        }
        .accessibilityLabel(localized("mr.list"))
    }
}

struct MainRow: View {
    let check: MainCheck
    let branch: String
    let presentation: MainPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(icon: presentation.icon, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: branch)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: String(check.sha.prefix(7)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                let commands = MainPresentation.commandsLine(check.commands)
                if !commands.isEmpty {
                    Text(verbatim: commands)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(verbatim: presentation.statusText)
                    .font(.system(size: 12, weight: presentation.tone == .blue ? .medium : .regular))
                    .foregroundStyle(presentation.tone.color)
            }
        }
        .padding(.vertical, 6)
    }
}

struct MRRow: View {
    let mr: MergeRequest
    let presentation: MRPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(icon: presentation.icon, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: mr.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: "!\(mr.iid)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "\(mr.sourceBranch) → \(mr.targetBranch)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !presentation.statusText.isEmpty {
                    Text(verbatim: presentation.statusText)
                        .font(.system(size: 12, weight: presentation.tone == .blue ? .medium : .regular))
                        .foregroundStyle(presentation.tone.color)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct MRDetail: View {
    @Environment(Workspace.self) private var workspace
    let mr: MergeRequest
    let run: MRRun
    var waitingOn: String?
    @State private var opened: [StageKind: Bool] = [:]
    @State private var reviewing = false
    @State private var confirmRevert = false

    var body: some View {
        let presentation = MRPresentation(run, waitingOn: waitingOn)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if run.status != .unknown || waitingOn != nil {
                    Banner(
                        icon: presentation.icon, title: presentation.bannerTitle, text: presentation.bannerBody,
                        lines: presentation.bodyLines
                    ) {
                        ForEach(visible(presentation.actions), id: \.self) { action in
                            actionButton(action)
                        }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(MRPresentation.stages(run, waitingOn: waitingOn).enumerated()), id: \.offset) {
                        _, stage in
                        StageRow(stage: stage, isOpen: isOpen(stage.kind)) {
                            opened[stage.kind] = !isOpen(stage.kind)
                        }
                    }
                }
                .accessibilityLabel(localized("mr.stagesTitle"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $reviewing) {
            if let fix = run.fix {
                FixReviewSheet(mr: mr, fix: fix)
            }
        }
        .alert(localized("fix.revertTitle"), isPresented: $confirmRevert) {
            Button(localized("projects.cancel"), role: .cancel) {}
            Button(localized("fix.revert"), role: .destructive) { workspace.revertFix(mr) }
        } message: {
            Text(verbatim: localized("fix.revertBody"))
        }
    }

    private func isOpen(_ kind: StageKind) -> Bool {
        opened[kind] ?? (MRPresentation.autoOpen(run, waitingOn: waitingOn) == kind)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: mr.title)
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                Text(
                    "\("!\(mr.iid) · \(mr.author) · ")\(Text(verbatim: "\(mr.sourceBranch) → \(mr.targetBranch)").font(.system(size: 11, design: .monospaced)))"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Link(destination: mr.webURL) {
                Label(localized("mr.openInGitlab"), systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func visible(_ actions: [MRPresentation.Action]) -> [MRPresentation.Action] {
        actions.filter { action in
            switch action {
            case .fix, .retryFix:
                workspace.canFix(mr)
                    || (action == .retryFix && run.fix?.phase == .gaveUp && workspace.claude?.status == .ready)
            case .revert: workspace.canRevert(mr)
            case .terminal: run.fix?.sessionID != nil && workspace.claude?.status == .ready
            default: true
            }
        }
    }

    @ViewBuilder private func actionButton(_ action: MRPresentation.Action) -> some View {
        let button = Button {
            perform(action)
        } label: {
            if action.hasStar {
                Label(action.title, systemImage: "sparkle")
            } else {
                Text(verbatim: action.title)
            }
        }
        .buttonBorderShape(.capsule)
        if action.isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private func perform(_ action: MRPresentation.Action) {
        switch action {
        case .run, .retry: workspace.start(mr)
        case .stop: workspace.stop(mr)
        case .rerunCI: workspace.rerunCI(mr)
        case .fix, .retryFix: workspace.startFix(mr)
        case .stopFix: workspace.stopFix(mr)
        case .reject: workspace.rejectFix(mr)
        case .view: reviewing = true
        case .revert: confirmRevert = true
        case .terminal: workspace.continueInTerminal(mr)
        case .recheck: workspace.recheckFix(mr)
        }
    }
}

struct Banner<Actions: View>: View {
    let icon: MRPresentation.Icon
    let title: String
    let text: String
    let lines: Int
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(icon: icon, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .fontWeight(.semibold)
                if !text.isEmpty {
                    Text(verbatim: text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(lines)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                actions
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}

struct StageRow: View {
    let stage: Stage
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if !stage.log.isEmpty { toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    StageIcon(state: stage.state)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: MRPresentation.stageName(stage.kind))
                            .fontWeight(.semibold)
                            .foregroundStyle(nameStyle)
                        let subtitle = MRPresentation.subtitle(stage)
                        if !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.system(size: 11, design: stage.caption == .command ? .monospaced : .default))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(
                        verbatim: stage.state == .done || stage.state == .failed
                            ? MRPresentation.duration(stage.duration) : ""
                    )
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .opacity(stage.log.isEmpty ? 0 : 1)
                }
                .padding(8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen && !stage.log.isEmpty {
                LogBox(
                    lines: stage.log, state: stage.state,
                    thinking: (stage.kind == .claude || stage.kind == .pick) && stage.state == .running
                )
                .padding(.leading, 36)
                .padding(.bottom, 6)
            }
        }
    }

    private var nameStyle: Color {
        switch stage.state {
        case .pending, .skipped: .secondary
        case .failed: .red
        default: .primary
        }
    }
}

struct LogBox: View {
    let lines: [LogLine]
    let state: StageState
    var thinking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let kind = MRPresentation.displayKind(line, stageState: state)
                    Text(verbatim: MRPresentation.text(line))
                        .font(kind == .claude ? .system(size: 12) : .system(size: 11.5, design: .monospaced))
                        .italic(kind == .note)
                        .foregroundStyle(kind.color)
                        .padding(.vertical, kind == .claude ? 2 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if thinking {
                    Text(verbatim: localized("fix.thinking"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 210)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}

struct StatusIcon: View {
    let icon: MRPresentation.Icon
    let size: CGFloat

    var body: some View {
        Group {
            switch icon {
            case .spinner:
                ProgressView().controlSize(size > 20 ? .regular : .small)
            case .check:
                Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(.white, .green)
            case .cross:
                Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(.white, .red)
            case .down:
                Image(systemName: "arrow.down.circle.fill").resizable().foregroundStyle(.white, .orange)
            case .redo:
                Image(systemName: "arrow.clockwise.circle.fill").resizable().foregroundStyle(.white, .orange)
            case .none:
                Image(systemName: "circle").resizable().foregroundStyle(.tertiary)
            case .claudeSpinner:
                ProgressView().controlSize(size > 20 ? .regular : .small).tint(.purple)
            case .dots:
                Image(systemName: "ellipsis.circle.fill").resizable().foregroundStyle(.white, .purple)
            case .pause:
                Image(systemName: "pause.circle").resizable().foregroundStyle(.tertiary)
            case .star:
                Circle().fill(.purple).overlay {
                    Image(systemName: "sparkle").resizable().scaledToFit().padding(size * 0.22).foregroundStyle(.white)
                }
            case .brokenCross:
                Image(systemName: "xmark.circle.fill").resizable().foregroundStyle(.white, .orange)
            }
        }
        .frame(width: size, height: size)
    }
}

struct StageIcon: View {
    let state: StageState

    var body: some View {
        switch state {
        case .done: StatusIcon(icon: .check, size: 18)
        case .failed: StatusIcon(icon: .cross, size: 18)
        case .running: ProgressView().controlSize(.small)
        case .skipped: Image(systemName: "minus.circle").resizable().foregroundStyle(.tertiary)
        case .pending: Image(systemName: "circle").resizable().foregroundStyle(.tertiary)
        }
    }
}

extension MRPresentation.Tone {
    var color: Color {
        switch self {
        case .blue: .blue
        case .green, .secondary: .secondary
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        }
    }
}

extension MRPresentation.Action {
    var title: String {
        switch self {
        case .run: localized("mr.runNow")
        case .stop, .stopFix: localized("mr.stop")
        case .retry, .retryFix: localized("mr.retry")
        case .rerunCI: localized("mr.rerunCi")
        case .fix: localized("mr.fix")
        case .reject: localized("fix.reject")
        case .view: localized("fix.view")
        case .revert: localized("fix.revert") + "…"
        case .terminal: localized("fix.terminal")
        case .recheck: localized("fix.recheck")
        }
    }
}

extension LogLine.Kind {
    var color: Color {
        switch self {
        case .command: .primary
        case .ok: .green
        case .error: .red
        case .note: .orange
        case .output: .secondary
        case .claude: .purple
        case .tool: .primary
        }
    }
}
