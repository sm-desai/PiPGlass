import AppKit
import ApplicationServices

// Private but long-stable AX SPI that maps an AXUIElement window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Moves the real Firefox PiP window (almost) off-screen with the Accessibility API and puts it back later.
final class Parker {
    private struct Parked {
        let element: AXUIElement
        let windowID: CGWindowID
        let originalOrigin: CGPoint
        let parkedOrigin: CGPoint
    }

    private var parked: Parked?

    var parkedWindowID: CGWindowID? { parked?.windowID }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// `frame` is the window frame in global top-left-origin coordinates (as reported by ScreenCaptureKit).
    @discardableResult
    func park(windowID: CGWindowID, pid: pid_t, frame: CGRect, title: String, visiblePixels: CGFloat) -> Bool {
        if parked?.windowID == windowID { return true }
        restore()
        guard Self.isTrusted else {
            Log.info("park: Accessibility permission not granted; leaving PiP window in place")
            return false
        }
        guard let element = Self.findWindow(pid: pid, windowID: windowID, frame: frame, title: title) else {
            Log.info("park: could not find AX window for \(windowID)")
            return false
        }
        // The caller's frame can be stale (e.g. still the parked position); ask AX where it really is.
        let current = CGRect(origin: Self.position(of: element) ?? frame.origin, size: frame.size)
        let target = Self.parkingOrigin(for: current, visiblePixels: visiblePixels)
        guard Self.setPosition(element, target) else {
            Log.info("park: setting position failed")
            return false
        }
        let actual = Self.position(of: element) ?? target
        parked = Parked(element: element, windowID: windowID, originalOrigin: current.origin, parkedOrigin: actual)
        Log.info("park: moved window \(windowID) from \(current.origin) to requested \(target), actual \(actual)")
        return true
    }

    /// Returns the PiP window to where it was before parking. Safe to call when nothing is parked.
    func restore() {
        guard let p = parked else { return }
        parked = nil
        if Self.setPosition(p.element, p.originalOrigin) {
            Log.info("park: restored window \(p.windowID) to \(p.originalOrigin)")
        } else {
            Log.info("park: restore failed for window \(p.windowID) (probably closed)")
        }
    }

    /// Move the parked window back to its parking spot (it was moved on-screen).
    func reassert() {
        guard let p = parked else { return }
        _ = Self.setPosition(p.element, p.parkedOrigin)
    }

    /// Forget the parked window without moving it (it has closed).
    func forget(windowID: CGWindowID) {
        if parked?.windowID == windowID { parked = nil }
    }

    /// Current origin of the parked window, to detect Firefox/user moving it back.
    func currentParkedOrigin() -> (actual: CGPoint, expected: CGPoint)? {
        guard let p = parked, let pos = Self.position(of: p.element) else { return nil }
        return (pos, p.parkedOrigin)
    }

    // MARK: Geometry

    /// Bottom corner of the window's screen, pushed past the edge so only
    /// `visiblePixels` remain on-screen. Picks a corner with no neighbouring display.
    private static func parkingOrigin(for frame: CGRect, visiblePixels: CGFloat) -> CGPoint {
        let screens = NSScreen.screens.map(cgFrame(of:))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let home = screens.first(where: { $0.contains(center) }) ?? screens.first ?? .zero
        let v = max(0, visiblePixels)
        // Only bottom corners: macOS clamps windows below the menu bar, so a top corner
        // leaves the whole window visible. At the bottom the window server still keeps a
        // ~40x32pt sliver on-screen; Firefox keeps rendering at full rate either way.
        let candidates = [
            CGPoint(x: home.maxX - v, y: home.maxY - v),               // bottom-right
            CGPoint(x: home.minX - frame.width + v, y: home.maxY - v), // bottom-left
        ]
        // Prefer the candidate that overlaps the fewest on-screen pixels.
        func overlap(_ origin: CGPoint) -> CGFloat {
            let r = CGRect(origin: origin, size: frame.size)
            return screens.reduce(0) { acc, s in
                let i = r.intersection(s)
                return acc + (i.isNull ? 0 : i.width * i.height)
            }
        }
        let forced = UserDefaults.standard.integer(forKey: "parkCorner") // debug: 1 or 2 forces a corner
        if (1...candidates.count).contains(forced) { return candidates[forced - 1] }
        return candidates.min(by: { overlap($0) < overlap($1) }) ?? candidates[0]
    }

    /// NSScreen frame converted to global top-left-origin coordinates.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    // MARK: AX helpers

    private static func findWindow(pid: pid_t, windowID: CGWindowID, frame: CGRect, title: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success, id == windowID { return w }
        }
        // Fallback: match by title and size.
        return windows.first { w in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            guard (t as? String) == title, let size = size(of: w) else { return false }
            return abs(size.width - frame.width) < 2 && abs(size.height - frame.height) < 2
        }
    }

    private static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
    }
}
