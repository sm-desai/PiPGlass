import AppKit

/// Persisted user preferences (UserDefaults).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    static let minOpacity = 0.2
    static let maxOpacity = 1.0

    private init() {
        d.register(defaults: [
            "opacity": 0.6,
            "clickThrough": true,
            "overlayVisible": true,
            "parkSource": true,
            "pipTitle": "Picture-in-Picture",
            // Pixels of the parked Firefox PiP window left on-screen.
            "parkVisiblePixels": 0,
        ])
    }

    var opacity: Double {
        get { min(Self.maxOpacity, max(Self.minOpacity, d.double(forKey: "opacity"))) }
        set { d.set(min(Self.maxOpacity, max(Self.minOpacity, newValue)), forKey: "opacity") }
    }

    var clickThrough: Bool {
        get { d.bool(forKey: "clickThrough") }
        set { d.set(newValue, forKey: "clickThrough") }
    }

    var overlayVisible: Bool {
        get { d.bool(forKey: "overlayVisible") }
        set { d.set(newValue, forKey: "overlayVisible") }
    }

    var parkSource: Bool {
        get { d.bool(forKey: "parkSource") }
        set { d.set(newValue, forKey: "parkSource") }
    }

    /// Title of Firefox's PiP window. Overridable with
    /// `defaults write <bundle id> pipTitle "…"` for non-English Firefox builds.
    var pipTitle: String { d.string(forKey: "pipTitle") ?? "Picture-in-Picture" }

    var parkVisiblePixels: CGFloat { CGFloat(d.integer(forKey: "parkVisiblePixels")) }

    /// Overlay frame in AppKit screen coordinates.
    var overlayFrame: NSRect? {
        get { d.string(forKey: "overlayFrame").map(NSRectFromString).flatMap { $0.width > 10 ? $0 : nil } }
        set { d.set(newValue.map(NSStringFromRect), forKey: "overlayFrame") }
    }
}
