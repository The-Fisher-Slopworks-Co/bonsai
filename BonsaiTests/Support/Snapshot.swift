import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SNAPSHOTS"] == "1" }

    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/shots")
    }

    static func save<V: View>(
        _ name: String, size: CGSize? = nil, appearance: NSAppearance.Name = .aqua, wait: Duration = .milliseconds(800),
        sheet: (some View)? = Optional<EmptyView>.none, _ view: V
    ) async throws {
        let controller = NSHostingController(rootView: view)
        if size == nil { controller.sizingOptions = [.preferredContentSize] }
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.appearance = NSAppearance(named: appearance)
        if let size { window.setContentSize(size) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: wait)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).png").path
        let view = window.contentView!.superview ?? window.contentView!
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
