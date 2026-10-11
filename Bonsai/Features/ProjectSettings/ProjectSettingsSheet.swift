import SwiftUI

struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectSettingsModel
    let claudeSettings: ClaudeSettings
    let onSave: (Project) -> Void

    init(project: Project, client: GitLabClient?, claudeSettings: ClaudeSettings, onSave: @escaping (Project) -> Void) {
        _model = State(initialValue: ProjectSettingsModel(project: project, client: client))
        self.claudeSettings = claudeSettings
        self.onSave = onSave
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
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow(alignment: .center) {
                    label(L("projects.branch"))
                    Picker(L("projects.branch"), selection: $model.draft.targetBranch) {
                        ForEach(model.branchNames, id: \.self) { name in
                            Text(verbatim: model.isDefault(name) ? "\(name) — \(L("projects.defaultTag"))" : name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label(L("projects.setup"))
                    command($model.draft.setup, placeholder: "./scripts/setup.sh", hint: L("projects.setupHint"))
                }
                GridRow {
                    label(L("projects.test"))
                    command($model.draft.test, placeholder: "make test", hint: L("projects.testHint"))
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
                                Text(verbatim: L("ps.claude.\(mode.rawValue)")).tag(mode)
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
                    label(L("ps.notes"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $model.draft.rules, prompt: Text(verbatim: L("ps.notesPh")), axis: .vertical)
                            .lineLimit(3...5)
                            .textFieldStyle(.roundedBorder)
                        Text(verbatim: L("ps.notesHint")).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(model.draft.claude == .off)
                    .opacity(model.draft.claude == .off ? 0.5 : 1)
                }
            }
            HStack {
                Spacer()
                Button(L("projects.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("ps.save")) {
                    onSave(model.saved())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding(.top, 20)
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

    private func command(_ text: Binding<String>, placeholder: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: text, prompt: Text(verbatim: placeholder), axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
