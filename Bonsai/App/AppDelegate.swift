import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var notifier: Notifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppModel.isTesting else { return }
        let app = AppModel.shared
        app.applyDockIcon()
        app.applyOpenAtLogin()
        statusItem = StatusItemController(app: app)
        notifier = Notifier(app: app)
        app.startIfSignedIn()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { AppModel.shared.showMain() }
        return true
    }
}
