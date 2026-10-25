import AppKit
import ScreenCaptureKit

/// Menu bar icon and its menu. The menu is rebuilt each time it opens.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private unowned let app: AppController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let opacityLabel = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider(value: 60, minValue: 20, maxValue: 100, target: nil, action: nil)
    private lazy var opacityItem: NSMenuItem = makeOpacityItem()

    init(app: AppController) {
        self.app = app
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pip", accessibilityDescription: "PiPGlass")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "PiPGlass"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private var statusLine: NSMenuItem?

    /// Update the parts that can change while the menu is open (or the icon while closed).
    func refresh() {
        let pct = Int((app.settings.opacity * 100).rounded())
        opacitySlider.doubleValue = Double(pct)
        opacityLabel.stringValue = "Opacity: \(pct)%"
        statusItem.button?.appearsDisabled = app.source == nil
        statusLine?.title = statusText()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let s = app.settings

        let line = disabled(statusText())
        statusLine = line
        menu.addItem(line)
        if app.screenRecordingGranted == false {
            menu.addItem(item("Open Screen Recording Settings…", #selector(openScreenRecordingSettings)))
        }
        if s.parkSource && !app.accessibilityGranted {
            menu.addItem(item("Open Accessibility Settings… (needed to hide Firefox’s PiP)", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        refresh()
        menu.addItem(opacityItem)
        menu.addItem(item("Click-Through   ⌃⌥T", #selector(toggleClickThrough), on: s.clickThrough))
        menu.addItem(item("Show Overlay   ⌃⌥H", #selector(toggleOverlay), on: s.overlayVisible))
        menu.addItem(item("Hide Firefox’s PiP Window (park it off-screen)", #selector(toggleParking), on: s.parkSource))
        menu.addItem(.separator())

        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu()
        menu.addItem(sourceItem)
        menu.addItem(.separator())

        menu.addItem(disabled("Opacity ⌃⌥↑ / ⌃⌥↓"))
        menu.addItem(item("Quit PiPGlass", #selector(quit), key: "q"))
    }

    private func statusText() -> String {
        if app.screenRecordingGranted == false { return "⚠︎ Needs Screen Recording permission" }
        guard let src = app.source else {
            if case .manual = app.mode { return "Waiting for selected window…" }
            return "Waiting for Firefox Picture-in-Picture…"
        }
        let title = src.title.isEmpty ? "untitled window" : src.title
        var text = "Mirroring “\(title)”"
        if app.isParked { text += " (hidden)" }
        if !app.settings.overlayVisible { text += " — overlay hidden" }
        return text
    }

    private func sourceMenu() -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let auto = item("Automatic: Firefox Picture-in-Picture", #selector(selectAutomatic),
                        on: app.mode == .automatic)
        sub.addItem(auto)
        sub.addItem(.separator())

        let windows = app.firefoxWindows.filter { $0.isOnScreen || $0.windowID == app.source?.id }
        if windows.isEmpty {
            sub.addItem(disabled("No Firefox windows found"))
        }
        for w in windows.sorted(by: { app.isPiPCandidate($0) && !app.isPiPCandidate($1) }) {
            var title = w.title ?? ""
            if title.isEmpty { title = "(untitled)" }
            if title.count > 60 { title = String(title.prefix(57)) + "…" }
            let mi = item("\(title)  —  \(Int(w.frame.width))×\(Int(w.frame.height))",
                          #selector(selectWindow(_:)),
                          on: app.mode == .manual(w.windowID))
            mi.tag = Int(w.windowID)
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(item("Refresh List", #selector(refreshSources)))
        return sub
    }

    private func makeOpacityItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        opacityLabel.frame = NSRect(x: 14, y: 24, width: 230, height: 18)
        opacityLabel.font = .menuFont(ofSize: 0)
        opacitySlider.frame = NSRect(x: 14, y: 2, width: 232, height: 22)
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        view.addSubview(opacityLabel)
        view.addSubview(opacitySlider)
        let mi = NSMenuItem()
        mi.view = view
        return mi
    }

    // MARK: Item helpers

    private func item(_ title: String, _ action: Selector, on: Bool = false, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.state = on ? .on : .off
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    // MARK: Actions

    @objc private func opacityChanged(_ sender: NSSlider) {
        app.setOpacity(sender.doubleValue / 100)
    }
    @objc private func toggleClickThrough() { app.toggleClickThrough() }
    @objc private func toggleOverlay() { app.toggleOverlayVisible() }
    @objc private func toggleParking() { app.toggleParking() }
    @objc private func selectAutomatic() { app.selectSource(.automatic) }
    @objc private func selectWindow(_ sender: NSMenuItem) { app.selectSource(.manual(CGWindowID(sender.tag))) }
    @objc private func refreshSources() { app.poll() }
    @objc private func quit() { app.quit() }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func openAccessibilitySettings() {
        Parker.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
