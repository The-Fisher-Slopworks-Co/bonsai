// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct ConnectView: View {
    @State private var model: ConnectModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var focus: Field?

    enum Field { case server, token }

    init(store: Store) {
        _model = State(initialValue: ConnectModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 52)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            VStack(spacing: 16) {
                fields
                if model.trustShown { trustBox }
            }
            .padding(.horizontal, 32)
            footer
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 24)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focus = model.server.isEmpty ? .server : .token }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image("BonsaiGlyph")
                .renderingMode(.template)
                .resizable()
                .frame(width: 44, height: 44)
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.247, green: 0.690, blue: 0.416), Color(red: 0.122, green: 0.478, blue: 0.271),
                        ],
                        startPoint: .top, endPoint: .bottom),
                    in: .rect(cornerRadius: 16)
                )
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text(verbatim: localized("connect.title"))
                .font(.system(size: 26, weight: .semibold))
            Text(verbatim: localized("connect.intro"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                row(localized("connect.server")) {
                    TextField(
                        localized("connect.server"), text: $model.server,
                        prompt: Text(verbatim: "https://gitlab.example.com")
                    )
                    .textContentType(.URL)
                    .focused($focus, equals: .server)
                    .overlay(errorOutline(model.phase == .unreachable))
                    .onSubmit { focus = .token }
                }
                Divider().padding(.leading, 12)
                row(localized("connect.token")) {
                    HStack(spacing: 4) {
                        Group {
                            if model.reveal {
                                TextField(
                                    localized("connect.token"), text: $model.token, prompt: Text(verbatim: "glpat-…"))
                            } else {
                                SecureField(
                                    localized("connect.token"), text: $model.token, prompt: Text(verbatim: "glpat-…"))
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focus, equals: .token)
                        .overlay(errorOutline(model.phase == .badToken))
                        .onSubmit(connect)
                        Button {
                            model.reveal.toggle()
                        } label: {
                            Image(systemName: model.reveal ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(localized(model.reveal ? "connect.hideToken" : "connect.showToken"))
                        .accessibilityLabel(localized(model.reveal ? "connect.hideToken" : "connect.showToken"))
                    }
                }
            }
            .groupBox()
            hint
                .padding(.horizontal, 12)
        }
    }

    private var hint: some View {
        var text = AttributedString(localized("connect.hintA"))
        var scope = AttributedString("api")
        scope.font = .system(size: 11, design: .monospaced)
        text += scope
        text += AttributedString(localized("connect.hintC"))
        var link = AttributedString(localized("connect.hintLink"))
        link.link = model.tokenPageURL
        text += link
        return Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private var trustBox: some View {
        Toggle(localized("connect.trust"), isOn: $model.trust)
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .groupBox()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.isConnected {
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if model.phase == .checking {
                            ProgressView().controlSize(.small)
                        }
                        Text(verbatim: localized(model.phase == .checking ? "connect.connecting" : "connect.connect"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConnect)
            }
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .connected(let username):
            Label {
                Text("\(localized("connect.connectedAs")) \(Text(verbatim: "@" + username).bold())")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
            }
            .font(.system(size: 12))
        case .badToken, .unreachable, .certificate:
            Label {
                Text(verbatim: errorText)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
            }
            .font(.system(size: 12))
        case .idle, .checking:
            EmptyView()
        }
    }

    private var errorText: String {
        switch model.phase {
        case .badToken: localized("connect.errToken")
        case .certificate: localized("connect.errCert")
        default: localized("connect.errUrl")
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: label)
                .frame(width: 128, alignment: .leading)
            content()
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func errorOutline(_ shown: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.red, lineWidth: 2)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func connect() {
        Task {
            guard await model.connect() else { return }
            try? await Task.sleep(for: .seconds(1.1))
            openWindow(id: WindowID.main)
            dismissWindow(id: WindowID.connect)
        }
    }
}

extension View {
    func groupBox() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
