import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

#if PIPGLASS_DEBUG
// Development-only. Not compiled into normal builds: any process running as you could send these
// signals, and the snapshot would hand it a screenshot without its own Screen Recording permission.
// Build with `PIPGLASS_DEBUG=1 ./build.sh` to include them.

/// Self-test hooks, driven by signals so they need no UI:
///   kill -USR1 <pid>  → writes frame.png (last captured frame) and screen.png (whole display,
///                       including the overlay) to ~/Library/Logs/PiPGlass/
///   kill -USR2 <pid>  → restores and re-parks the PiP window (re-reads the parking defaults)
extension AppController {
    func writeDebugSnapshots() {
        let dir = Log.url.deletingLastPathComponent()
        if let frame = capture.lastFrameImage() {
            Self.writePNG(frame, to: dir.appendingPathComponent("frame.png"))
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let screen = overlay.screen ?? NSScreen.main
                let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
                else { return }
                let corner = CGRect(x: display.frame.maxX - 120, y: display.frame.maxY - 120, width: 120, height: 120)
                for w in content.windows where w.frame.intersects(corner) && w.isOnScreen {
                    Log.info("debug: corner window id=\(w.windowID) app=\(w.owningApplication?.bundleIdentifier ?? "?") layer=\(w.windowLayer) title=\"\(loggableTitle(w.title))\" frame=\(w.frame)")
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                Self.writePNG(image, to: dir.appendingPathComponent("screen.png"))
                Log.info("debug: wrote snapshots (overlay frame \(overlay.frame), visible \(overlay.isVisible), alpha \(overlay.alphaValue))")
            } catch {
                Log.info("debug: screenshot failed: \(error.localizedDescription)")
            }
        }
    }

    /// SIGUSR2: runs the command in ~/Library/Logs/PiPGlass/debug-command (then deletes it):
    ///   source auto | source <windowID> | frame <x> <y> <width> | toggle-park | repark (default)
    func runDebugCommand() {
        let url = Log.url.deletingLastPathComponent().appendingPathComponent("debug-command")
        let cmd = ((try? String(contentsOf: url, encoding: .utf8)) ?? "repark")
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        try? FileManager.default.removeItem(at: url)
        Log.info("debug: command \(cmd)")
        switch cmd.first {
        case "source" where cmd.count == 2:
            if cmd[1] == "auto" { selectSource(.automatic) }
            else if let id = UInt32(cmd[1]) { selectSource(.manual(id)) }
        case "frame" where cmd.count == 4:
            // Same path as the end of a mouse drag/resize.
            guard let x = Double(cmd[1]), let y = Double(cmd[2]), let w = Double(cmd[3]) else { return }
            overlay.setFrame(NSRect(x: x, y: y, width: w, height: (w / overlay.aspect).rounded()), display: true)
            overlay.onFrameCommitted?()
        case "toggle-park":
            toggleParking()
        default:
            repark()
        }
    }

    func repark() {
        parker.restore()
        if let s = source, let pid = s.window.owningApplication?.processID {
            parker.park(windowID: s.id, pid: pid, frame: s.frame, title: s.title,
                        visiblePixels: settings.parkVisiblePixels)
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
#endif
