import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab(L("settings.tab.general"), systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab(L("settings.tab.claude"), systemImage: "sparkle") {
                ClaudeSettingsView()
            }
            Tab(L("settings.tab.notifications"), systemImage: "bell") {
                NotificationSettingsView()
            }
            Tab(L("settings.tab.account"), systemImage: "person.crop.circle") {
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
            Section(L("settings.checkingTitle")) {
                Picker(L("settings.interval"), selection: $store.settings.interval) {
                    ForEach([CheckInterval.everyMinute, .every5, .every15, .every30, .manual], id: \.self) { interval in
                        Text(verbatim: L("settings.interval.\(interval.rawValue)")).tag(interval)
                    }
                }
                LabeledContent(L("settings.parallel")) {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(store.settings.parallel)").monospacedDigit()
                        Stepper(L("settings.parallel"), value: $store.settings.parallel, in: Bonsai.Settings.parallelRange)
                            .labelsHidden()
                    }
                }
            }
            Section {
                Picker(L("settings.whichTitle"), selection: $store.settings.scope) {
                    Text(verbatim: L("settings.scopeMine")).tag(MRScope.mine)
                    Text(verbatim: L("settings.scopeAll")).tag(MRScope.all)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                if store.settings.scope == .all {
                    Text(verbatim: L("settings.scopeAllHint"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Toggle(L("settings.skipDrafts"), isOn: $store.settings.skipDrafts)
                TextField(L("settings.skipLabel"), text: $store.settings.skipLabel)
            } header: {
                Text(verbatim: L("settings.whichTitle"))
            }
            Section(L("settings.appTitle")) {
                Toggle(L("settings.login"), isOn: $store.settings.openAtLogin)
                Toggle(L("settings.dock"), isOn: $store.settings.dockIcon)
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
                    Button(L("settings.choose"), action: choose)
                }
            } footer: {
                if let hint = check?.status.hint {
                    Text(verbatim: hint).foregroundStyle(.secondary)
                }
            }
            Group {
                Section {
                    Toggle(L("settings.autoConflict"), isOn: $store.settings.claude.onConflict)
                    Toggle(L("settings.autoTests"), isOn: $store.settings.claude.onTests)
                    Toggle(L("settings.autoCi"), isOn: $store.settings.claude.onCI)
                } header: {
                    Text(verbatim: L("settings.autoTitle"))
                } footer: {
                    Text(verbatim: L("settings.autoHint")).foregroundStyle(.secondary)
                }
                Section {
                    Picker(L("settings.pushTitle"), selection: $store.settings.claude.push) {
                        Text(verbatim: L("settings.pushReview")).tag(PushMode.review)
                        Text(verbatim: L("settings.pushAuto")).tag(PushMode.auto)
                    }
                    .pickerStyle(.radioGroup)
                    if store.settings.claude.push == .auto {
                        Text(verbatim: L("settings.pushAutoHint"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent(L("settings.attempts")) {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(store.settings.claude.attempts)").monospacedDigit()
                            Stepper(L("settings.attempts"), value: $store.settings.claude.attempts, in: Bonsai.Settings.attemptsRange)
                                .labelsHidden()
                        }
                    }
                } header: {
                    Text(verbatim: L("settings.fixesTitle"))
                } footer: {
                    Text(verbatim: L("settings.perProjectHint")).foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: Binding(
                        get: { store.settings.claude.rules ?? L("settings.rulesDefault") },
                        set: { store.settings.claude.rules = $0 == L("settings.rulesDefault") ? nil : $0 }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                } header: {
                    Text(verbatim: L("settings.rulesTitle"))
                } footer: {
                    Text(verbatim: L("settings.rulesHint")).foregroundStyle(.secondary)
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
        case .ready: L("settings.cliOk")
        case .notFound: L("settings.cliNotFound")
        case .needsLogin: L("settings.cliNotLoggedIn")
        }
    }

    var hint: String? {
        switch self {
        case .ready: nil
        case .notFound: L("settings.cliHintNotFound")
        case .needsLogin: L("settings.cliHintLogin")
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
            Section(L("settings.notifyWhen")) {
                row(L("settings.nClaudeReady"), nil, icon: "ellipsis.circle.fill", color: .purple, isOn: $store.settings.notifications.claudeReady)
                row(L("settings.nNeedsMe"), L("settings.nNeedsMeSub"), icon: "xmark.circle.fill", color: .red, isOn: $store.settings.notifications.needsMe)
                row(L("settings.nAuth"), nil, icon: "xmark.circle.fill", color: .orange, isOn: $store.settings.notifications.noConnection)
                row(L("settings.nOk"), nil, icon: "checkmark.circle.fill", color: .green, isOn: $store.settings.notifications.updated)
                row(L("settings.nStart"), nil, icon: "play.circle.fill", color: .blue, isOn: $store.settings.notifications.started)
            }
            Section {
                Toggle(L("settings.quiet"), isOn: $store.settings.notifications.quietWhileWindowOpen)
            } footer: {
                Text(systemHint).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private var systemHint: AttributedString {
        var text = AttributedString(L("settings.systemHintA"))
        var link = AttributedString(L("settings.systemHintLink"))
        link.link = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        text += link
        text += AttributedString(".")
        return text
    }

    private func row(_ title: String, _ subtitle: String?, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
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
                    LabeledContent(L("settings.token")) {
                        HStack(spacing: 8) {
                            if let text = model?.tokenText {
                                Text(verbatim: text).foregroundStyle(model?.connection == .tokenExpired ? .red : .secondary)
                            }
                            Button(L("settings.changeToken")) { app.changeToken() }
                        }
                    }
                    Toggle(isOn: Binding(get: { account.trustedFingerprint != nil }, set: { on in Task { await model?.setTrust(on) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: L("settings.tls"))
                            Text(verbatim: L("settings.tlsHint"))
                                .font(.callout)
                                .foregroundStyle(account.trustedFingerprint != nil ? .orange : .secondary)
                        }
                    }
                }
                Section(L("settings.gitAuthor")) {
                    TextField(L("settings.gitName"), text: Binding(get: { app.store.settings.gitIdentity.name },
                                                                    set: { app.store.settings.gitIdentity.name = $0 }))
                    TextField(L("settings.gitEmail"), text: Binding(get: { app.store.settings.gitIdentity.email },
                                                                     set: { app.store.settings.gitIdentity.email = $0 }))
                }
                Section {
                    Button(L("settings.signOut"), role: .destructive) { app.signOut() }
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
