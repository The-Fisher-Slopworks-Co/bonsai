import Foundation
import Observation

@MainActor
@Observable
final class AddProjectModel {
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var results: [GitLabProject] = []
    private(set) var searched = false
    var selectedID: Int? { didSet { if selectedID != oldValue { selectionChanged() } } }
    private(set) var branches: [GitLabBranch] = []
    var branch: String?
    var setup = ""
    var test = "" { didSet { if test != oldValue && !applyingDetection { detectedFrom = nil } } }
    private(set) var detectedFrom: String?

    private let client: GitLabClient
    private let excluded: Set<Int>
    private let debounce: Duration
    private var searchTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var applyingDetection = false

    init(client: GitLabClient, excluded: Set<Int>, debounce: Duration = .milliseconds(250)) {
        self.client = client
        self.excluded = excluded
        self.debounce = debounce
    }

    var selected: GitLabProject? { results.first { $0.id == selectedID } }

    var canAdd: Bool {
        selected != nil && branch != nil && !test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var testHint: String {
        if let detectedFrom, !test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("projects.foundIn", detectedFrom) + " " + L("projects.testHint")
        }
        return L("projects.testHint")
    }

    func start() {
        search(immediately: true)
    }

    func project() -> Project? {
        guard canAdd, let selected, let branch else { return nil }
        return Project(id: selected.id, name: selected.name, path: selected.path, webURL: selected.webURL,
                       cloneURL: selected.cloneURL, defaultBranch: selected.defaultBranch ?? branch, targetBranch: branch,
                       setup: setup.trimmingCharacters(in: .whitespacesAndNewlines),
                       test: test.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func settle() async {
        await searchTask?.value
        await detailsTask?.value
    }

    private func search(immediately: Bool = false) {
        searchTask?.cancel()
        let term = query
        let delay = immediately ? .zero : debounce
        searchTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = (try? await client.projects(search: term)) ?? []
            guard !Task.isCancelled else { return }
            results = found.filter { !excluded.contains($0.id) }
            searched = true
            if selected == nil { selectedID = results.first?.id }
        }
    }

    private func selectionChanged() {
        detailsTask?.cancel()
        branches = []
        branch = nil
        applyDetection(nil)
        guard let project = selected else { return }
        detailsTask = Task {
            let loaded = (try? await client.branches(project: project.id, defaultBranch: project.defaultBranch)) ?? []
            guard !Task.isCancelled, selectedID == project.id else { return }
            branches = loaded
            let base = loaded.first(where: \.isDefault)?.name ?? project.defaultBranch ?? loaded.first?.name
            branch = base
            guard let base else { return }
            let client = self.client
            let files = (try? await client.rootFiles(project: project.id, ref: base)) ?? []
            let found = try? await CommandDetector.detect(files: files) { path in
                try await client.file(project: project.id, path: path, ref: base)
            }
            guard !Task.isCancelled, selectedID == project.id else { return }
            applyDetection(found ?? nil)
        }
    }

    private func applyDetection(_ found: DetectedCommands?) {
        applyingDetection = true
        setup = found?.setup ?? ""
        test = found?.test ?? ""
        detectedFrom = found?.source
        applyingDetection = false
    }
}
