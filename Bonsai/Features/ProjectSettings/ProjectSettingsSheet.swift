// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectSettingsModel
    let claudeSettings: ClaudeSettings
    let onSave: (Project) -> Void
    var onApply: (Project) -> Void = { _ in }
    var onReject: () -> Void = {}

    init(
        project: Project, client: GitLabClient?, claudeSettings: ClaudeSettings, proposal: MainCheck.Proposal? = nil,
        onSave: @escaping (Project) -> Void, onApply: @escaping (Project) -> Void = { _ in },
        onReject: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: ProjectSettingsModel(project: project, client: client, proposal: proposal))
        self.claudeSettings = claudeSettings
        self.onSave = onSave
        self.onApply = onApply
        self.onReject = onReject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.original.name).font(.headline)
                Text(verbatim: model.original.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
            if let proposal = model.proposal {
                claudeSummary(proposal)
                    .padding(.bottom, 16)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow(alignment: .center) {
                    label(localized("projects.branch"))
                    Picker(localized("projects.branch"), selection: $model.draft.targetBranch) {
                        ForEach(model.branchNames, id: \.self) { name in
                            Text(
                                verbatim: model.isDefault(name) ? "\(name) — \(localized("projects.defaultTag"))" : name
                            ).tag(
                                name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label(localized("projects.setup"))
                    command(
                        $model.draft.setup, .setup, placeholder: "./scripts/setup.sh",
                        hint: localized("projects.setupHint"))
                }
                GridRow {
                    label(localized("projects.test"))
                    command($model.draft.test, .test, placeholder: "make test", hint: localized("projects.testHint"))
                }
                Divider().gridCellColumns(2)
                GridRow(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle").foregroundStyle(.orange)
                        Text(verbatim: "Claude")
                    }
                    .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Claude", selection: $model.draft.claude) {
                            ForEach(ClaudeMode.allCases, id: \.self) { mode in
                                Text(verbatim: localized("ps.claude.\(mode.rawValue)")).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if let hint = ProjectSettingsModel.claudeHint(model.draft.claude, settings: claudeSettings) {
                            Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    label(localized("ps.notes"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "", text: $model.draft.rules, prompt: Text(verbatim: localized("ps.notesPh")),
                            axis: .vertical
                        )
                        .lineLimit(3...5)
                        .textFieldStyle(.roundedBorder)
                        Text(verbatim: localized("ps.notesHint")).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(model.draft.claude == .off)
                    .opacity(model.draft.claude == .off ? 0.5 : 1)
                }
            }
            if model.proposal != nil {
                reviewButtons
            } else {
                HStack {
                    Spacer()
                    Button(localized("projects.cancel"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(localized("ps.save")) {
                        onSave(model.saved())
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
                }
                .padding(.top, 20)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.load() }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .frame(width: 90, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private var reviewButtons: some View {
        HStack {
            Button(localized("fix.reject")) {
                onReject()
                dismiss()
            }
            .foregroundStyle(.red)
            Spacer()
            Button(localized("main.later"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if model.isEdited {
                Button(localized("main.check", model.draft.targetBranch)) {
                    onSave(model.saved())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.draft.test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button(localized("main.apply")) {
                    onApply(model.saved())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 20)
    }

    private func claudeSummary(_ proposal: MainCheck.Proposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(icon: .star, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: proposal.summary)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isEdited {
                    HStack(spacing: 12) {
                        badge(localized("main.verified", model.original.targetBranch))
                        badge(localized("main.codeUntouched"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.purple.opacity(0.1), in: .rect(cornerRadius: 10))
    }

    private func badge(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func command(
        _ text: Binding<String>, _ kind: ProjectSettingsModel.Command, placeholder: String, hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: text, prompt: Text(verbatim: placeholder), axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if let was = model.was(kind) {
                Text(
                    "\(localized("main.was"))\(Text(verbatim: was).font(.system(size: 11, design: .monospaced)))"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
