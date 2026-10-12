// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(Workspace.self) private var workspace
    @Environment(Scheduler.self) private var scheduler
    @State private var selection: Int?
    @State private var mrSelection: [Int: String] = [:]
    @State private var addingProject = false
    @State private var editing: Project?
    @State private var removing: Project?

    private var store: Store { workspace.store }
    private var selected: Project? { store.projects.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
        }
        .navigationTitle(selected?.name ?? "Bonsai")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(isPresented: $addingProject) {
            if let client = workspace.client() {
                AddProjectSheet(client: client, excluded: Set(store.projects.map(\.id))) { project in
                    workspace.add(project)
                    selection = project.id
                }
            }
        }
        .sheet(item: $editing) { project in
            ProjectSettingsSheet(project: project, client: workspace.client(), claudeSettings: store.settings.claude) {
                saved in
                workspace.update(saved)
                if !saved.paused { workspace.check(saved) }
            }
        }
        .alert(
            removing.map { localized("ps.alertTitle", $0.name) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button(localized("projects.cancel"), role: .cancel) { removing = nil }
            Button(localized("ps.delete"), role: .destructive) {
                guard let project = removing else { return }
                removing = nil
                if selection == project.id { selection = store.projects.first { $0.id != project.id }?.id }
                Task { await workspace.remove(project) }
            }
        } message: {
            Text(verbatim: localized("ps.alertBody"))
        }
        .onAppear {
            if selection == nil { selection = store.projects.first?.id }
            follow(app.route)
        }
        .onChange(of: app.route) { follow(app.route) }
    }

    private func follow(_ route: AppModel.Route?) {
        guard let route else { return }
        selection = route.projectID
        if let mr = route.mrID { mrSelection[route.projectID] = mr }
        app.route = nil
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section(localized("projects.title")) {
                ForEach(store.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu { contextMenu(project) }
                }
            }
        }
    }

    @ViewBuilder private func contextMenu(_ project: Project) -> some View {
        Button(localized("ps.mSettings")) { editing = project }
        Button(localized(project.paused ? "ps.mResume" : "ps.mPause")) { togglePause(project) }
        Link(localized("ps.mOpenGitlab"), destination: project.webURL)
        Divider()
        Button(localized("ps.mDelete"), role: .destructive) { removing = project }
    }

    private func togglePause(_ project: Project) {
        var changed = project
        changed.paused.toggle()
        workspace.update(changed)
        if !changed.paused { workspace.check(changed) }
    }

    private var subtitle: String {
        guard let project = selected else { return store.account?.server.host() ?? "" }
        let state = workspace.state(project)
        guard state.loading == .loaded else { return project.path }
        return MRPresentation.subtitle(
            project: project, count: state.mergeRequests.count, checkedAt: state.checkedAt,
            waiting: workspace.isWaiting(project))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                scheduler.checkNow()
            } label: {
                Label(localized("projects.refresh"), systemImage: "arrow.clockwise")
            }
            .help(localized("projects.refresh"))
            .disabled(store.projects.isEmpty)
            Button {
                addingProject = true
            } label: {
                Label(localized("projects.addAria"), systemImage: "plus")
            }
            .help(localized("projects.addAria"))
            Button {
                editing = selected
            } label: {
                Label(localized("mr.projectSettings"), systemImage: "slider.horizontal.3")
            }
            .help(localized("mr.projectSettings"))
            .disabled(selected == nil)
        }
    }

    @ViewBuilder private var detail: some View {
        if store.projects.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(verbatim: localized("projects.emptyTitle"))
                } icon: {
                    Image("ProjectGlyph").resizable().frame(width: 48, height: 48)
                }
            } description: {
                Text(verbatim: localized("projects.emptyBody"))
            } actions: {
                Button(localized("projects.add")) { addingProject = true }
            }
        } else if let project = selected {
            ProjectDetail(
                project: project,
                selection: Binding(
                    get: { mrSelection[project.id] },
                    set: { mrSelection[project.id] = $0 }
                ),
                onEdit: { editing = project }
            )
            .id(project.id)
        }
    }
}

struct ProjectRow: View {
    @Environment(Workspace.self) private var workspace
    let project: Project

    var body: some View {
        let state = workspace.state(project)
        let main = workspace.mainCheck(project).map { MainPresentation($0, branch: project.targetBranch) }
        let mainBusy = main.map { $0.icon == .spinner || $0.icon == .claudeSpinner } ?? false
        let busy =
            mainBusy
            || state.mergeRequests.contains { if case .running = workspace.run($0).status { true } else { false } }
        HStack(spacing: 6) {
            Label {
                Text(verbatim: project.name).lineLimit(1)
            } icon: {
                Image("ProjectGlyph").foregroundStyle(.tint)
            }
            Spacer(minLength: 4)
            if project.paused {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                    .help(localized("ps.paused"))
                    .accessibilityLabel(localized("ps.paused"))
            }
            if busy {
                ProgressView().controlSize(.mini)
            } else if let main, MainPresentation.isVisible(workspace.mainCheck(project)) {
                StatusIcon(icon: main.icon, size: 12)
                    .help(main.statusText)
                    .accessibilityLabel(main.statusText)
            }
            if state.loading == .loaded {
                Text(verbatim: "\(state.mergeRequests.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
