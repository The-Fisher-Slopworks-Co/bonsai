// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(localized("settings.tab.general"), systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab(localized("settings.tab.claude"), systemImage: "sparkle") {
                ClaudeSettingsView()
            }
            Tab(localized("settings.tab.notifications"), systemImage: "bell") {
                NotificationSettingsView()
            }
            Tab(localized("settings.tab.account"), systemImage: "person.crop.circle") {
                AccountSettings()
            }
        }
        .frame(width: 540)
        .scenePadding(.bottom)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var store = app.store
        Form {
            Section(localized("settings.checkingTitle")) {
                Picker(localized("settings.interval"), selection: $store.settings.interval) {
                    ForEach([CheckInterval.everyMinute, .every5, .every15, .every30, .manual], id: \.self) { interval in
                        Text(verbatim: localized("settings.interval.\(interval.rawValue)")).tag(interval)
                    }
                }
                LabeledContent(localized("settings.parallel")) {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(store.settings.parallel)").monospacedDigit()
                        Stepper(
                            localized("settings.parallel"), value: $store.settings.parallel,
                            in: Bonsai.Settings.parallelRange
                        )
                        .labelsHidden()
                    }
                }
            }
            Section {
                Picker(localized("settings.whichTitle"), selection: $store.settings.scope) {
                    Text(verbatim: localized("settings.scopeMine")).tag(MRScope.mine)
                    Text(verbatim: localized("settings.scopeAll")).tag(MRScope.all)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                if store.settings.scope == .all {
                    Text(verbatim: localized("settings.scopeAllHint"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Toggle(localized("settings.skipDrafts"), isOn: $store.settings.skipDrafts)
                TextField(localized("settings.skipLabel"), text: $store.settings.skipLabel)
            } header: {
                Text(verbatim: localized("settings.whichTitle"))
            }
            Section(localized("settings.appTitle")) {
                Toggle(localized("settings.login"), isOn: $store.settings.openAtLogin)
                Toggle(localized("settings.dock"), isOn: $store.settings.dockIcon)
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
        .onChange(of: store.settings.interval) { app.scheduler.reschedule() }
        .onChange(of: store.settings.dockIcon) { app.applyDockIcon() }
        .onChange(of: store.settings.openAtLogin) { app.applyOpenAtLogin() }
        .onChange(of: store.settings.scope) { app.workspace.checkAll() }
        .onChange(of: store.settings.skipDrafts) { app.workspace.checkAll() }
    }
}

struct ClaudeSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var check: ClaudeCLI.Check?

    var body: some View {
        @Bindable var store = app.store
        let ready = check?.status == .ready
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.orange.gradient, in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Claude Code").fontWeight(.semibold)
                        Text(verbatim: check?.path ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if let check {
                        HStack(spacing: 5) {
                            Circle().fill(check.status.color).frame(width: 8, height: 8)
                            Text(verbatim: check.status.title).font(.callout)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button(localized("settings.choose"), action: choose)
                }
            } footer: {
                if let hint = check?.status.hint {
                    Text(verbatim: hint).foregroundStyle(.secondary)
                }
            }
            Group {
                Section {
                    Toggle(localized("settings.autoConflict"), isOn: $store.settings.claude.onConflict)
                    Toggle(localized("settings.autoTests"), isOn: $store.settings.claude.onTests)
                    Toggle(localized("settings.autoCi"), isOn: $store.settings.claude.onCI)
                } header: {
                    Text(verbatim: localized("settings.autoTitle"))
                } footer: {
                    Text(verbatim: localized("settings.autoHint")).foregroundStyle(.secondary)
                }
                Section {
                    Picker(localized("settings.pushTitle"), selection: $store.settings.claude.push) {
                        Text(verbatim: localized("settings.pushReview")).tag(PushMode.review)
                        Text(verbatim: localized("settings.pushAuto")).tag(PushMode.auto)
                    }
                    .pickerStyle(.radioGroup)
                    if store.settings.claude.push == .auto {
                        Text(verbatim: localized("settings.pushAutoHint"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent(localized("settings.attempts")) {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(store.settings.claude.attempts)").monospacedDigit()
                            Stepper(
                                localized("settings.attempts"), value: $store.settings.claude.attempts,
                                in: Bonsai.Settings.attemptsRange
                            )
                            .labelsHidden()
                        }
                    }
                } header: {
                    Text(verbatim: localized("settings.fixesTitle"))
                } footer: {
                    Text(verbatim: localized("settings.perProjectHint")).foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(
                        text: Binding(
                            get: { store.settings.claude.rules ?? localized("settings.rulesDefault") },
                            set: { store.settings.claude.rules = $0 == localized("settings.rulesDefault") ? nil : $0 }
                        )
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                } header: {
                    Text(verbatim: localized("settings.rulesTitle"))
                } footer: {
                    Text(verbatim: localized("settings.rulesHint")).foregroundStyle(.secondary)
                }
            }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.45)
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .task(id: store.settings.claude.path) {
            check = nil
            check = await ClaudeCLI.check(custom: store.settings.claude.path)
            app.workspace.claude = check
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: check?.path ?? "/opt/homebrew/bin").deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            app.store.settings.claude.path = url.path
        }
    }
}

extension ClaudeCLI.Status {
    var title: String {
        switch self {
        case .ready: localized("settings.cliOk")
        case .notFound: localized("settings.cliNotFound")
        case .needsLogin: localized("settings.cliNotLoggedIn")
        }
    }

    var hint: String? {
        switch self {
        case .ready: nil
        case .notFound: localized("settings.cliHintNotFound")
        case .needsLogin: localized("settings.cliHintLogin")
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .notFound: .red
        case .needsLogin: .orange
        }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var store = app.store
        Form {
            Section(localized("settings.notifyWhen")) {
                row(
                    localized("settings.nClaudeReady"), nil, icon: "ellipsis.circle.fill", color: .purple,
                    isOn: $store.settings.notifications.claudeReady)
                row(
                    localized("settings.nNeedsMe"), localized("settings.nNeedsMeSub"), icon: "xmark.circle.fill",
                    color: .red,
                    isOn: $store.settings.notifications.needsMe)
                row(
                    localized("settings.nAuth"), nil, icon: "xmark.circle.fill", color: .orange,
                    isOn: $store.settings.notifications.noConnection)
                row(
                    localized("settings.nOk"), nil, icon: "checkmark.circle.fill", color: .green,
                    isOn: $store.settings.notifications.updated)
                row(
                    localized("settings.nStart"), nil, icon: "play.circle.fill", color: .blue,
                    isOn: $store.settings.notifications.started)
            }
            Section {
                Toggle(localized("settings.quiet"), isOn: $store.settings.notifications.quietWhileWindowOpen)
            } footer: {
                Text(systemHint).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private var systemHint: AttributedString {
        var text = AttributedString(localized("settings.systemHintA"))
        var link = AttributedString(localized("settings.systemHintLink"))
        link.link = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        text += link
        text += AttributedString(".")
        return text
    }

    private func row(_ title: String, _ subtitle: String?, icon: String, color: Color, isOn: Binding<Bool>) -> some View
    {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                    if let subtitle {
                        Text(verbatim: subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(.white, color)
            }
        }
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var app
    @State private var model: AccountModel?

    var body: some View {
        Form {
            if let account = app.store.account {
                Section {
                    HStack(spacing: 12) {
                        Text(verbatim: String(account.username.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.gradient, in: .circle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "@" + account.username).fontWeight(.semibold)
                            Text(verbatim: account.server.host() ?? account.server.absoluteString)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let state = model?.connection {
                            HStack(spacing: 5) {
                                Circle().fill(state.color).frame(width: 8, height: 8)
                                Text(verbatim: state.title).font(.callout)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                Section {
                    LabeledContent(localized("settings.token")) {
                        HStack(spacing: 8) {
                            if let text = model?.tokenText {
                                Text(verbatim: text).foregroundStyle(
                                    model?.connection == .tokenExpired ? .red : .secondary)
                            }
                            Button(localized("settings.changeToken")) { app.changeToken() }
                        }
                    }
                    Toggle(
                        isOn: Binding(
                            get: { account.trustedFingerprint != nil },
                            set: { on in Task { await model?.setTrust(on) } })
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: localized("settings.tls"))
                            Text(verbatim: localized("settings.tlsHint"))
                                .font(.callout)
                                .foregroundStyle(account.trustedFingerprint != nil ? .orange : .secondary)
                        }
                    }
                }
                Section(localized("settings.gitAuthor")) {
                    TextField(
                        localized("settings.gitName"),
                        text: Binding(
                            get: { app.store.settings.gitIdentity.name },
                            set: { app.store.settings.gitIdentity.name = $0 }))
                    TextField(
                        localized("settings.gitEmail"),
                        text: Binding(
                            get: { app.store.settings.gitIdentity.email },
                            set: { app.store.settings.gitIdentity.email = $0 }))
                }
                Section {
                    Button(localized("settings.signOut"), role: .destructive) { app.signOut() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
        .task {
            let model = AccountModel(app: app)
            self.model = model
            await model.refresh()
        }
    }
}
