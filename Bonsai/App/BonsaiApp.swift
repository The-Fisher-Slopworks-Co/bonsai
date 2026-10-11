import SwiftUI

enum WindowID {
    static let main = "main"
    static let connect = "connect"
}

@main
struct BonsaiApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel.shared

    var body: some Scene {
        Window("Bonsai", id: WindowID.main) {
            MainView()
                .environment(app)
                .environment(app.workspace)
                .environment(app.scheduler)
                .modifier(CaptureWindowActions(app: app))
                .onAppear { app.startIfSignedIn() }
                .onChange(of: app.store.settings.interval) { app.scheduler.reschedule() }
        }
        .defaultLaunchBehavior(app.store.isSignedIn ? .presented : .suppressed)

        Window(localized("connect.title"), id: WindowID.connect) {
            ConnectView(store: app.store)
                .modifier(CaptureWindowActions(app: app))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(app.store.isSignedIn ? .suppressed : .presented)

        SwiftUI.Settings {
            SettingsView()
                .environment(app)
                .modifier(CaptureWindowActions(app: app))
        }
    }
}
