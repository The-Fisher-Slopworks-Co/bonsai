import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    private let dot = NSView()

    var isDotShown: Bool { !dot.isHidden }

    init(app: AppModel) {
        self.app = app
        super.init()
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("Bonsai")
            button.wantsLayer = true
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = 3
            dot.frame = NSRect(x: button.bounds.width - 8, y: button.bounds.height - 9, width: 6, height: 6)
            dot.autoresizingMask = [.minXMargin, .minYMargin]
            dot.isHidden = true
            button.addSubview(dot)
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        observe()
    }

    private func model() -> MenuBarModel {
        MenuBarModel(items: app.workspace.allMergeRequests.map { ($0.0, app.workspace.run($0.0)) },
                     isChecking: app.workspace.isChecking, lastCheck: app.workspace.lastCheck, pausedUntil: app.scheduler.pausedUntil)
    }

    private func observe() {
        let current = withObservationTracking {
            model()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        updateIcon(current)
    }

    private func updateIcon(_ model: MenuBarModel) {
        dot.isHidden = !model.hasProblems
        guard let layer = item.button?.layer else { return }
        if model.isWorking {
            if layer.animation(forKey: "pulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.9
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                layer.add(pulse, forKey: "pulse")
            }
        } else {
            layer.removeAnimation(forKey: "pulse")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = model()

        let header = NSMenuItem()
        header.view = NSHostingView(rootView: MenuHeader(text: model.headerText) { [weak self] in
            self?.menu.cancelTracking()
            self?.app.scheduler.checkNow()
        })
        header.view?.frame.size = header.view?.fittingSize ?? .zero
        menu.addItem(header)

        for section in model.sections {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: section.title))
            for entry in section.items {
                menu.addItem(mrItem(entry))
            }
        }
        if model.freshCount > 0 {
            menu.addItem(.separator())
            let fresh = NSMenuItem(title: L("menu.fresh", model.freshCount), action: nil, keyEquivalent: "")
            fresh.image = Self.icon(.check, size: 14)
            fresh.isEnabled = false
            menu.addItem(fresh)
        }

        menu.addItem(.separator())
        menu.addItem(action(L("menu.open"), #selector(openBonsai)))
        menu.addItem(action(L(model.isPaused ? "menu.resume" : "menu.pause"), #selector(togglePause)))
        menu.addItem(action(L("menu.settings"), #selector(openSettings), key: ","))
        menu.addItem(action(L("menu.quit"), #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func mrItem(_ entry: MenuBarModel.Item) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(openMR(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry
        let text = NSMutableAttributedString(string: entry.title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
        text.append(NSAttributedString(string: "  !\(entry.iid)", attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        text.append(NSAttributedString(string: "\n" + entry.status, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: Self.color(entry.tone)]))
        item.attributedTitle = text
        item.image = Self.icon(entry.icon, size: 14)
        return item
    }

    static func color(_ tone: MRPresentation.Tone) -> NSColor {
        switch tone {
        case .blue: .linkColor
        case .red: .systemRed
        case .orange: .systemOrange
        case .green, .secondary: .secondaryLabelColor
        case .purple: .systemPurple
        }
    }

    static func icon(_ icon: MRPresentation.Icon, size: CGFloat) -> NSImage? {
        let (name, color): (String, NSColor) = switch icon {
        case .spinner: ("arrow.triangle.2.circlepath.circle.fill", .controlAccentColor)
        case .check: ("checkmark.circle.fill", .systemGreen)
        case .cross: ("xmark.circle.fill", .systemRed)
        case .down: ("arrow.down.circle.fill", .systemOrange)
        case .redo: ("arrow.clockwise.circle.fill", .systemOrange)
        case .none: ("circle", .tertiaryLabelColor)
        case .claudeSpinner: ("arrow.triangle.2.circlepath.circle.fill", .systemPurple)
        case .dots: ("ellipsis.circle.fill", .systemPurple)
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(.init(paletteColors: [.white, color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    @objc private func openMR(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuBarModel.Item else { return }
        app.showMain(project: entry.projectID, mr: entry.mrID)
    }

    @objc private func openBonsai() { app.showMain() }

    @objc private func togglePause() {
        if app.scheduler.isPaused { app.scheduler.resume() } else { app.scheduler.pauseForHour() }
    }

    @objc private func openSettings() { app.showSettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}

private struct MenuHeader: View {
    let text: String
    let refresh: () -> Void

    var body: some View {
        HStack {
            Text(verbatim: text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L("menu.refresh"))
            .accessibilityLabel(L("menu.refresh"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(width: 300, height: 26)
    }
}
