import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let shared =
        isTesting
        ? AppModel(
            store: Store(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "bonsai-host-\(UUID().uuidString)"),
                keychain: Keychain(service: "dev.txssu.Bonsai.tests.host")))
        : AppModel()

    struct Route: Equatable {
        var projectID: Int
        var mrID: String?
    }

    let store: Store
    let workspace: Workspace
    let scheduler: Scheduler
    var route: Route?
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored var openSettings: OpenSettingsAction?
    @ObservationIgnored var onStatusChange: [(Workspace.StatusChange) -> Void] = []
    private var started = false

    init(store: Store = Store()) {
        self.store = store
        workspace = Workspace(store: store)
        scheduler = Scheduler(workspace: workspace)
        workspace.onStatusChange = { [weak self] change in
            self?.onStatusChange.forEach { $0(change) }
        }
        workspace.openTerminal = { url in NSWorkspace.shared.open(url) }
    }

    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func startIfSignedIn() {
        guard !started, store.isSignedIn, !Self.isTesting else { return }
        started = true
        scheduler.start()
        refreshClaude()
    }

    func refreshClaude() {
        let custom = store.settings.claude.path
        Task {
            workspace.claude = await ClaudeCLI.check(custom: custom)
        }
    }

    func showMain(project: Int? = nil, mr: String? = nil) {
        if let project { route = Route(projectID: project, mrID: mr) }
        NSApp.activate()
        openWindow?(id: store.isSignedIn ? WindowID.main : WindowID.connect)
    }

    func showSettings() {
        NSApp.activate()
        openSettings?()
    }

    func changeToken() {
        NSApp.activate()
        openWindow?(id: WindowID.connect)
    }

    func signOut() {
        scheduler.stop()
        workspace.cancelAll()
        store.signOut()
        store.saveTrustedCertificate(nil)
        started = false
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(WindowID.main) ?? false {
            window.close()
        }
        NSApp.keyWindow?.close()
        changeToken()
    }

    func applyDockIcon() {
        guard !Self.isTesting else { return }
        NSApp.setActivationPolicy(store.settings.dockIcon ? .regular : .accessory)
    }

    func applyOpenAtLogin() {
        guard !Self.isTesting else { return }
        let service = SMAppService.mainApp
        if store.settings.openAtLogin {
            if service.status != .enabled { try? service.register() }
        } else if service.status == .enabled {
            try? service.unregister()
        }
    }

    var isMainWindowVisible: Bool {
        NSApp.windows.contains {
            ($0.identifier?.rawValue.hasPrefix(WindowID.main) ?? false) && $0.isVisible && !$0.isMiniaturized
        }
    }
}

struct CaptureWindowActions: ViewModifier {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            app.openWindow = openWindow
            app.openSettings = openSettings
        }
    }
}
