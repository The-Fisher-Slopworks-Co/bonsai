// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct FixReviewSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let mr: MergeRequest
    let fix: ClaudeFix
    @State private var selection = 0
    @State private var restOpen = false
    @State private var message: String

    init(mr: MergeRequest, fix: ClaudeFix) {
        self.mr = mr
        self.fix = fix
        _message = State(initialValue: fix.commitMessage)
    }

    private var decide: Bool { fix.phase == .ready }
    private var files: [FixFile] { FixReview.ordered(fix.files) }
    private var multi: Bool { files.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Divider()
            HStack(spacing: 0) {
                if multi {
                    navigation
                        .frame(width: 240)
                    Divider()
                }
                if files.indices.contains(selection) {
                    FileChanges(file: files[selection], showNote: multi)
                } else {
                    Color.clear
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            commitRow
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: multi ? 940 : 760, height: multi ? 656 : 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: FixReview.title(fix))
                .font(.system(size: 17, weight: .semibold))
            if !fix.summary.isEmpty {
                Text(verbatim: fix.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                ForEach(FixReview.badges(fix), id: \.text) { badge in
                    Label {
                        Text(verbatim: badge.text)
                    } icon: {
                        Image(systemName: badge.warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(.white, badge.warning ? Color.orange : Color.green)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((badge.warning ? Color.orange : Color.green).opacity(0.12), in: .capsule)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var navigation: some View {
        List(selection: Binding(get: { selection }, set: { selection = $0 ?? 0 })) {
            if fix.kind == .conflict {
                let attention = files.indices.filter { FixReview.needsAttention(files[$0]) }
                let rest = files.indices.filter { !FixReview.needsAttention(files[$0]) }
                if !attention.isEmpty {
                    Section(localized("fix.grpCheck")) {
                        ForEach(attention, id: \.self) { navRow($0) }
                    }
                }
                if !rest.isEmpty {
                    let collapsible = rest.count > 5
                    Section(
                        isExpanded: Binding(
                            get: { !collapsible || restOpen || rest.contains(selection) }, set: { restOpen = $0 })
                    ) {
                        ForEach(rest, id: \.self) { navRow($0) }
                    } header: {
                        Text(verbatim: localized("fix.grpRest"))
                    }
                }
            } else {
                Section(localized("fix.changesNav")) {
                    ForEach(files.indices, id: \.self) { navRow($0) }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }

    private func navRow(_ index: Int) -> some View {
        let file = files[index]
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(FixReview.kindColor(file))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: (file.path as NSString).lastPathComponent).lineLimit(1)
                Text(verbatim: FixReview.subtitle(file))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tag(index)
    }

    @ViewBuilder private var commitRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: localized("fix.commitLabel"))
                .fontWeight(.semibold)
            if fix.kind == .conflict {
                Text(verbatim: localized("fix.noCommit"))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                TextField(localized("fix.commitLabel"), text: $message)
                    .labelsHidden()
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!decide)
                if decide {
                    Text(verbatim: localized("fix.commitHint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if decide {
                Button(localized("fix.reject")) {
                    workspace.rejectFix(mr)
                    dismiss()
                }
                if fix.sessionID != nil {
                    Button(localized("fix.terminal")) {
                        workspace.continueInTerminal(mr)
                        dismiss()
                    }
                }
                Spacer()
                Button(localized("fix.later")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(localized("fix.push")) {
                    workspace.pushFix(mr, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fix.kind != .conflict && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Spacer()
                Button(localized("fix.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

private struct FileChanges: View {
    let file: FixFile
    let showNote: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: file.path)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(verbatim: FixReview.subtitle(file))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(FixReview.legend(file), id: \.self) { origin in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(FixReview.color(origin)).frame(width: 3, height: 10)
                            Text(verbatim: FixReview.originTitle(origin)).font(.system(size: 11)).foregroundStyle(
                                .secondary)
                        }
                    }
                }
                if showNote, let note = file.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                switch file.kind {
                case .diff:
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        DiffBlock(rows: FixReview.rows(hunk))
                    }
                case .conflict:
                    ForEach(Array(file.conflicts.enumerated()), id: \.offset) { _, conflict in
                        DiffBlock(rows: FixReview.rows(conflict))
                        if !conflict.dropped.isEmpty {
                            Text(verbatim: localized("fix.dropped"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            DiffBlock(
                                rows: conflict.dropped.map {
                                    FixReview.Row(
                                        number: "", text: $0.text, bar: FixReview.color($0.origin), tint: .clear,
                                        dim: true)
                                })
                        }
                    }
                case .lock:
                    Text(
                        verbatim: localized("fix.kind.lock") + ", " + localized("fix.conflictsN", file.conflicts.count)
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DiffBlock: View {
    let rows: [FixReview.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    Text(verbatim: row.number)
                        .frame(width: 36, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 8)
                    Rectangle().fill(row.bar).frame(width: 3)
                        .padding(.trailing, 10)
                    Text(verbatim: row.text.isEmpty ? " " : row.text)
                        .foregroundStyle(row.dim ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
                .background(row.tint)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }
}

enum FixReview {
    struct Badge: Hashable {
        var text: String
        var warning: Bool
    }

    struct Row {
        var number: String
        var text: String
        var bar: Color
        var tint: Color
        var dim: Bool
    }

    static func title(_ fix: ClaudeFix) -> String {
        switch fix.kind {
        case .tests: localized("fix.sheetTitle.tests")
        case .ci: localized("fix.sheetTitle.ci", fix.job ?? "CI")
        case .conflict: localized("fix.sheetTitle.conflict", fix.resolvedConflicts)
        }
    }

    static func badges(_ fix: ClaudeFix) -> [Badge] {
        let verified = localized("fix.verified") + (fix.phase == .pushed ? " · " + localized("fix.pushedBadge") : "")
        var badges = [Badge(text: verified, warning: false)]
        if fix.kind != .conflict {
            badges.append(
                fix.testsTouched
                    ? Badge(text: localized("fix.testsTouched"), warning: true)
                    : Badge(text: localized("fix.testsUntouched"), warning: false))
        }
        return badges
    }

    static func needsAttention(_ file: FixFile) -> Bool {
        file.kind == .conflict && (file.hasOwnCode || file.conflicts.isEmpty)
    }

    static func ordered(_ files: [FixFile]) -> [FixFile] {
        files.filter(needsAttention) + files.filter { !needsAttention($0) }
    }

    static func subtitle(_ file: FixFile) -> String {
        switch file.kind {
        case .diff:
            return MRPresentation.stat(added: file.added, removed: file.removed)
        case .lock:
            return localized("fix.conflictsN", file.conflicts.count) + " · " + localized("fix.kind.lock")
        case .conflict:
            guard let first = file.conflicts.first else { return localized("fix.kind.own") }
            let place =
                file.conflicts.count > 1
                ? localized("fix.conflictsN", file.conflicts.count)
                : first.startLine == first.endLine
                    ? localized("fix.line", first.startLine) : localized("fix.lines", first.startLine, first.endLine)
            return place + " · " + kindTitle(file)
        }
    }

    static func kindTitle(_ file: FixFile) -> String {
        if file.kind == .lock { return localized("fix.kind.lock") }
        if needsAttention(file) { return localized("fix.kind.own") }
        let sources = Set(file.conflicts.map(\.source))
        if sources == [.main] { return localized("fix.kind.main") }
        if sources == [.branch] { return localized("fix.kind.branch") }
        return localized("fix.kind.both")
    }

    static func kindColor(_ file: FixFile) -> Color {
        if needsAttention(file) { return .purple }
        let sources = Set(file.conflicts.map(\.source))
        if file.kind == .conflict && sources == [.main] { return .blue }
        if file.kind == .conflict && sources == [.branch] { return .orange }
        return .secondary
    }

    static func legend(_ file: FixFile) -> [ResolvedConflict.Line.Origin] {
        guard file.kind == .conflict else { return [] }
        let used = Set(file.conflicts.flatMap { $0.lines.map(\.origin) })
        return [.main, .branch, .own].filter(used.contains)
    }

    static func color(_ origin: ResolvedConflict.Line.Origin) -> Color {
        switch origin {
        case .main: .blue
        case .branch: .orange
        case .own: .purple
        case .context: .clear
        }
    }

    static func originTitle(_ origin: ResolvedConflict.Line.Origin) -> String {
        switch origin {
        case .main: localized("fix.fromMain")
        case .branch: localized("fix.fromBranch")
        case .own: localized("fix.fromClaude")
        case .context: ""
        }
    }

    static func rows(_ hunk: DiffHunk) -> [Row] {
        var rows = [Row(number: "", text: hunk.header, bar: .clear, tint: .clear, dim: true)]
        for line in hunk.lines {
            switch line.kind {
            case .added:
                rows.append(Row(number: "+", text: line.text, bar: .green, tint: .green.opacity(0.14), dim: false))
            case .removed:
                rows.append(Row(number: "−", text: line.text, bar: .red, tint: .red.opacity(0.11), dim: false))
            case .context: rows.append(Row(number: "", text: line.text, bar: .clear, tint: .clear, dim: true))
            }
        }
        return rows
    }

    static func rows(_ conflict: ResolvedConflict) -> [Row] {
        conflict.lines.map { line in
            Row(
                number: line.number.map(String.init) ?? "", text: line.text, bar: color(line.origin),
                tint: line.origin == .context ? .clear : color(line.origin).opacity(0.1), dim: line.origin == .context)
        }
    }
}
