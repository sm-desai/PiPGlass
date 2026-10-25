import AppKit
import ScreenCaptureKit

/// Ties together window discovery, capture, the overlay, parking and the menu.
@MainActor
final class AppController: NSObject, NSWindowDelegate {
    enum SourceMode: Equatable { case automatic, manual(CGWindowID) }

    struct Source {
        let window: SCWindow
        var frame: CGRect
        let isPiP: Bool
        var id: CGWindowID { window.windowID }
        var title: String { window.title ?? "" }
    }

    static let firefoxBundleIDs: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
    ]

    let settings = Settings.shared
    let overlay = OverlayPanel()
    let capture = WindowCapture()
    let parker = Parker()
    let patch = CornerPatch()
    private(set) var menu: MenuController!

    private(set) var mode: SourceMode = .automatic
    private(set) var source: Source?
    private(set) var firefoxWindows: [SCWindow] = []
    private(set) var screenRecordingGranted: Bool?

    private var pollTimer: Timer?
    private var polling = false
    private var captureBusy = false
    private var pointPixelScale: CGFloat = 1
    private var resizeWork: DispatchWorkItem?
    private var lastWindowListLog = ""
    /// PiP windows the user dragged back on-screen while parked; don't fight them.
    private var userUnparked: Set<CGWindowID> = []
    private var reparkTimes: [Date] = []

    func start() {
        menu = MenuController(app: self)

        overlay.delegate = self
        overlay.alphaValue = settings.opacity
        overlay.clickThrough = settings.clickThrough
        overlay.onFrameCommitted = { [weak self] in self?.overlayFrameChanged() }
        capture.onFrame = { [weak overlay] surface in
            DispatchQueue.main.async { overlay?.videoView.display(surface: surface) }
        }
        capture.onStopped = { [weak self] _ in
            guard let self else { return }
            Task { await self.detach(reason: "stream stopped"); self.poll() }
        }

        registerHotKeys()
        requestPermissions()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.tolerance = 0.2
        poll()
    }

    // MARK: Permissions

    private func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() {
            Log.info("permissions: Screen Recording not granted yet, requesting")
            CGRequestScreenCaptureAccess()
        }
        if settings.parkSource && !Parker.isTrusted {
            Log.info("permissions: Accessibility not granted yet, requesting")
            Parker.requestTrust()
        }
    }

    var accessibilityGranted: Bool { Parker.isTrusted }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let hk = HotKeyCenter.shared, mods = HotKeyCenter.controlOption
        hk.register(keyCode: 0x7E, modifiers: mods, name: "⌃⌥↑") { [weak self] in self?.nudgeOpacity(+0.1) }
        hk.register(keyCode: 0x7D, modifiers: mods, name: "⌃⌥↓") { [weak self] in self?.nudgeOpacity(-0.1) }
        hk.register(keyCode: 0x11, modifiers: mods, name: "⌃⌥T") { [weak self] in self?.toggleClickThrough() }
        hk.register(keyCode: 0x04, modifiers: mods, name: "⌃⌥H") { [weak self] in self?.toggleOverlayVisible() }
    }

    // MARK: User actions

    func setOpacity(_ value: Double) {
        settings.opacity = value
        overlay.alphaValue = settings.opacity
        overlay.videoView.flash("Opacity \(Int((settings.opacity * 100).rounded()))%")
        menu.refresh()
    }

    func nudgeOpacity(_ delta: Double) {
        // Snap to 10% steps.
        setOpacity(((settings.opacity + delta) * 10).rounded() / 10)
        Log.info("opacity -> \(Int(settings.opacity * 100))%")
    }

    func toggleClickThrough() {
        settings.clickThrough.toggle()
        overlay.clickThrough = settings.clickThrough
        overlay.videoView.flash(settings.clickThrough ? "Click-through ON" : "Click-through OFF — drag to move")
        Log.info("click-through -> \(settings.clickThrough)")
        menu.refresh()
    }

    func toggleOverlayVisible() {
        settings.overlayVisible.toggle()
        Log.info("overlay visible -> \(settings.overlayVisible)")
        Task { await updateCaptureState() }
        menu.refresh()
    }

    func toggleParking() {
        settings.parkSource.toggle()
        Log.info("park source -> \(settings.parkSource)")
        if settings.parkSource {
            userUnparked.removeAll()
            if !Parker.isTrusted { Parker.requestTrust() }
            parkIfNeeded()
        } else {
            parker.restore()
        }
        menu.refresh()
    }

    func selectSource(_ newMode: SourceMode) {
        guard newMode != mode else { return }
        mode = newMode
        Log.info("source mode -> \(newMode)")
        Task {
            await detach(reason: "source changed")
            poll()
        }
    }

    func quit() {
        parker.restore()
        NSApp.terminate(nil)
    }

    // MARK: Discovery

    func isFirefox(_ w: SCWindow) -> Bool {
        Self.firefoxBundleIDs.contains(w.owningApplication?.bundleIdentifier ?? "")
    }

    func isPiPCandidate(_ w: SCWindow) -> Bool {
        // A parked window may report as off-screen, so accept the current source regardless.
        (w.title ?? "") == settings.pipTitle && (w.isOnScreen || w.windowID == source?.id)
    }

    func poll() {
        guard !polling else { return }
        polling = true
        Task {
            defer { polling = false }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            } catch {
                if screenRecordingGranted != false {
                    Log.info("discovery: SCShareableContent failed (\(error.localizedDescription)) — Screen Recording permission missing?")
                    screenRecordingGranted = false
                    menu.refresh()
                }
                return
            }
            if screenRecordingGranted != true {
                screenRecordingGranted = true
                Log.info("discovery: Screen Recording permission OK")
                menu.refresh()
            }
            let windows = content.windows.filter {
                isFirefox($0) && $0.frame.width >= 60 && $0.frame.height >= 40
            }
            firefoxWindows = windows
            logWindowListIfChanged(windows)
            await reconcile(windows)
            // Cover the sliver of the parked PiP window that macOS keeps on-screen.
            let parkedNow = isParked ? windows.first(where: { $0.windowID == source?.id }) : nil
            await patch.update(pip: parkedNow, content: content,
                               excluding: [overlay.windowNumber, patch.windowNumber])
        }
    }

    /// Window titles can contain browsing history (including private windows), so the log only
    /// ever records the generic PiP title.
    func loggableTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "(untitled)" }
        return title == settings.pipTitle ? title : "(title hidden)"
    }

    private func logWindowListIfChanged(_ windows: [SCWindow]) {
        let desc = windows.map {
            "  id=\($0.windowID) layer=\($0.windowLayer) onScreen=\($0.isOnScreen) title=\"\(loggableTitle($0.title))\" frame=\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))"
        }.joined(separator: "\n")
        // Ignore pure position changes so parking doesn't spam the log.
        let key = windows.map { "\($0.windowID)|\($0.title ?? "")|\($0.isOnScreen)|\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ";")
        guard key != lastWindowListLog else { return }
        lastWindowListLog = key
        Log.info("discovery: Firefox windows (\(windows.count)):\n\(desc)")
    }

    private func reconcile(_ windows: [SCWindow]) async {
        if case let .manual(id) = mode, !windows.contains(where: { $0.windowID == id }) {
            Log.info("discovery: manually selected window \(id) is gone; back to automatic")
            mode = .automatic
        }
        let target: SCWindow? = {
            switch mode {
            case .automatic: return windows.first(where: isPiPCandidate)
            case let .manual(id): return windows.first(where: { $0.windowID == id })
            }
        }()

        if let current = source {
            guard let target, target.windowID == current.id else {
                await detach(reason: target == nil ? "source window closed" : "different source")
                if let target { await attach(target) }
                menu.refresh()
                return
            }
            let oldSize = current.frame.size
            source?.frame = target.frame
            if abs(oldSize.width - target.frame.width) > 1 || abs(oldSize.height - target.frame.height) > 1 {
                Log.info("discovery: source resized to \(Int(target.frame.width))x\(Int(target.frame.height))")
                overlay.aspect = target.frame.width / target.frame.height
                overlay.applyAspect(keepingWidth: overlay.frame.width)
                scheduleCaptureResize()
            }
            checkParkedPosition()
            parkIfNeeded()
            if !capture.isRunning { await updateCaptureState() }
        } else if let target {
            await attach(target)
            menu.refresh()
        }
    }

    // MARK: Attach / detach

    private func attach(_ w: SCWindow) async {
        let src = Source(window: w, frame: w.frame, isPiP: (w.title ?? "") == settings.pipTitle)
        source = src
        pointPixelScale = CGFloat(SCShareableContent.info(for: SCContentFilter(desktopIndependentWindow: w)).pointPixelScale)
        Log.info("attach: window \(w.windowID) \"\(loggableTitle(src.title))\" \(Int(w.frame.width))x\(Int(w.frame.height)) scale=\(pointPixelScale) pip=\(src.isPiP)")
        overlay.aspect = max(0.1, w.frame.width / max(1, w.frame.height))
        placeOverlay()
        await updateCaptureState()
        parkIfNeeded()
    }

    func detach(reason: String) async {
        guard let s = source else { return }
        Log.info("detach: window \(s.id) (\(reason))")
        source = nil
        parker.restore()
        await capture.stop()
        overlay.orderOut(nil)
        overlay.videoView.clear()
        menu.refresh()
    }

    /// Capture runs only while there is a source and the overlay is visible.
    private func updateCaptureState() async {
        guard !captureBusy else { return }
        captureBusy = true
        defer { captureBusy = false }
        let shouldRun = source != nil && settings.overlayVisible
        if shouldRun, let s = source {
            if !capture.isRunning {
                do {
                    try await capture.start(window: s.window, pixelSize: capturePixelSize())
                } catch {
                    Log.info("capture: start failed: \(error.localizedDescription)")
                    return
                }
            }
            if source?.id == s.id { overlay.orderFrontRegardless() }
        } else {
            overlay.orderOut(nil)
            await capture.stop()
        }
    }

    // MARK: Parking

    private func parkIfNeeded() {
        guard settings.parkSource, let s = source, s.isPiP,
              parker.parkedWindowID != s.id, !userUnparked.contains(s.id),
              Parker.isTrusted, let pid = s.window.owningApplication?.processID else { return }
        if parker.park(windowID: s.id, pid: pid, frame: s.frame, title: s.title,
                       visiblePixels: settings.parkVisiblePixels) {
            menu.refresh()
        }
    }

    /// If the parked PiP window comes back on-screen (Firefox snapping it back, or a drag on the
    /// visible corner), push it back. Give up after a few tries a minute so we never fight Firefox
    /// in a loop; the menu's "Hide Firefox's PiP Window" toggle is the way to bring it back on purpose.
    private func checkParkedPosition() {
        guard let id = parker.parkedWindowID, let pos = parker.currentParkedOrigin() else { return }
        guard hypot(pos.actual.x - pos.expected.x, pos.actual.y - pos.expected.y) > 4 else { return }
        let now = Date()
        reparkTimes = reparkTimes.filter { now.timeIntervalSince($0) < 60 }
        if reparkTimes.count < 5 {
            reparkTimes.append(now)
            Log.info("park: window \(id) came back to \(pos.actual); hiding it again")
            parker.reassert()
        } else {
            Log.info("park: window \(id) keeps coming back; leaving it at \(pos.actual)")
            parker.forget(windowID: id)
            userUnparked.insert(id)
            menu.refresh()
        }
    }

    var isParked: Bool { parker.parkedWindowID != nil && parker.parkedWindowID == source?.id }

    // MARK: Overlay geometry

    private func placeOverlay() {
        let aspect = overlay.aspect
        if let saved = settings.overlayFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            let h = (saved.width / aspect).rounded()
            overlay.setFrame(NSRect(x: saved.minX, y: saved.maxY - h, width: saved.width, height: h), display: true)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let w: CGFloat = 480, h = (w / aspect).rounded()
            overlay.setFrame(NSRect(x: vf.maxX - w - 24, y: vf.minY + 24, width: w, height: h), display: true)
            settings.overlayFrame = overlay.frame
        }
    }

    private func capturePixelSize() -> CGSize {
        let scale = overlay.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var size = CGSize(width: overlay.frame.width * scale, height: overlay.frame.height * scale)
        // Never ask for more pixels than the source window actually has.
        if let s = source {
            let srcW = s.frame.width * pointPixelScale
            if size.width > srcW {
                size = CGSize(width: srcW, height: srcW * size.height / size.width)
            }
        }
        return size
    }

    private func scheduleCaptureResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.capture.isRunning else { return }
            self.capture.update(pixelSize: self.capturePixelSize())
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func overlayFrameChanged() {
        guard source != nil else { return }
        settings.overlayFrame = overlay.frame
        scheduleCaptureResize()
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { overlayFrameChanged() }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated { overlayFrameChanged() }
    }

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        MainActor.assumeIsolated { overlayFrameChanged() }
    }
}
