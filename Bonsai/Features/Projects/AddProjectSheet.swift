// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct AddProjectSheet: View {
    @State private var model: AddProjectModel
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Project) -> Void

    init(client: GitLabClient, excluded: Set<Int>, onAdd: @escaping (Project) -> Void) {
        _model = State(initialValue: AddProjectModel(client: client, excluded: excluded))
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: localized("projects.sheetTitle"))
                .font(.headline)
                .padding(.bottom, 16)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    label("projects.project")
                    projectPicker
                }
                GridRow(alignment: .center) {
                    label("projects.branch")
                    branchPicker
                }
                GridRow {
                    label("projects.setup")
                    command($model.setup, placeholder: "./scripts/setup.sh", hint: localized("projects.setupHint"))
                }
                GridRow {
                    label("projects.test")
                    command($model.test, placeholder: "make test", hint: model.testHint)
                }
            }
            HStack {
                Spacer()
                Button(localized("projects.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(localized("projects.addButton")) {
                    guard let project = model.project() else { return }
                    onAdd(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 520)
        .task { model.start() }
    }

    private func label(_ key: String) -> some View {
        Text(verbatim: localized(key))
            .frame(width: 90, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private var projectPicker: some View {
        VStack(spacing: 6) {
            TextField(
                localized("projects.project"), text: $model.query,
                prompt: Text(verbatim: localized("projects.projectPh"))
            )
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .overlay(alignment: .trailing) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).padding(.trailing, 6)
            }
            List(selection: $model.selectedID) {
                ForEach(model.results) { project in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: project.name)
                        Text(verbatim: project.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .tag(project.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .frame(height: 172)
            .overlay {
                if model.searched && model.results.isEmpty {
                    Text(verbatim: localized("projects.noMatch")).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var branchPicker: some View {
        Picker(localized("projects.branch"), selection: $model.branch) {
            ForEach(model.branches, id: \.name) { branch in
                if branch.isDefault {
                    Text(verbatim: "\(branch.name) — \(localized("projects.defaultTag"))").tag(Optional(branch.name))
                } else {
                    Text(verbatim: branch.name).tag(Optional(branch.name))
                }
            }
            if model.branches.isEmpty {
                Text(verbatim: "—").tag(String?.none)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.branches.isEmpty)
    }

    private func command(_ text: Binding<String>, placeholder: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: text, prompt: Text(verbatim: placeholder), axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text(verbatim: hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
