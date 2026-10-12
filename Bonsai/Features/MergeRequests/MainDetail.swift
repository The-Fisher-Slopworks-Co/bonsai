// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct MainDetail: View {
    @Environment(Workspace.self) private var workspace
    let project: Project
    let check: MainCheck
    let onEdit: () -> Void
    @State private var opened: [Int: Bool] = [:]
    @State private var reviewing = false

    var body: some View {
        let presentation = MainPresentation(check, branch: project.targetBranch)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Banner(
                    icon: presentation.bannerIcon, title: presentation.bannerTitle, text: presentation.bannerBody,
                    lines: presentation.bodyLines
                ) {
                    ForEach(visible(presentation.actions), id: \.self) { action in
                        actionButton(action)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(MainPresentation.stages(check).enumerated()), id: \.offset) { index, stage in
                        StageRow(stage: stage, isOpen: isOpen(index)) { opened[index] = !isOpen(index) }
                    }
                }
                .accessibilityLabel(localized("mr.stagesTitle"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $reviewing) {
            ProjectSettingsSheet(
                project: project, client: workspace.client(), claudeSettings: workspace.store.settings.claude,
                proposal: check.proposal,
                onSave: { saved in
                    workspace.update(saved)
                    workspace.check(saved)
                },
                onApply: { saved in
                    workspace.update(saved)
                    workspace.applyMain(saved)
                },
                onReject: { workspace.rejectMain(project) })
        }
    }

    private func isOpen(_ index: Int) -> Bool {
        opened[index] ?? (MainPresentation.autoOpen(check) == index)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: project.targetBranch)
                    .font(.system(size: 17, weight: .semibold))
                Text(
                    "\("\(check.sha.prefix(7)) · ")\(Text(verbatim: "origin/\(project.targetBranch)").font(.system(size: 11, design: .monospaced)))"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Link(destination: project.webURL) {
                Label(localized("mr.openInGitlab"), systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func visible(_ actions: [MainPresentation.Action]) -> [MainPresentation.Action] {
        actions.filter { $0.hasStar ? workspace.canFixMain(project) : true }
    }

    @ViewBuilder private func actionButton(_ action: MainPresentation.Action) -> some View {
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

    private func perform(_ action: MainPresentation.Action) {
        switch action {
        case .edit: onEdit()
        case .fix, .pick: workspace.fixMain(project)
        case .stop: workspace.stopMain(project)
        case .reject: workspace.rejectMain(project)
        case .view: reviewing = true
        }
    }
}

extension MainPresentation.Action {
    var title: String {
        switch self {
        case .edit: localized("main.edit")
        case .fix: localized("mr.fix")
        case .pick: localized("main.pick")
        case .stop: localized("mr.stop")
        case .reject: localized("fix.reject")
        case .view: localized("fix.view")
        }
    }
}
