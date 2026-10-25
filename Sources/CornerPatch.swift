import AppKit
import ScreenCaptureKit

/// macOS keeps a ~40×32pt sliver of the parked Firefox PiP window on-screen. This covers that sliver
/// with a tiny window showing a live, low-rate capture of whatever is underneath it (the PiP window
/// itself excluded), so the corner looks empty.
final class CornerPatch: NSObject, SCStreamOutput, SCStreamDelegate {
    private let panel: NSPanel
    private let imageLayer = CALayer()
    private let queue = DispatchQueue(label: "pipglass.patch", qos: .utility)
    private var stream: SCStream?
    private var coveredRect: CGRect = .null   // global top-left coordinates
    private var coveredWindows: Set<CGWindowID> = []
    private var busy = false

    override init() {
        panel = PatchPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 32),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        // Above Firefox's floating PiP window, below the overlay.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // Swallow clicks so they don't land on the hidden PiP window.
        panel.ignoresMouseEvents = false
        let view = NSView()
        view.wantsLayer = true
        imageLayer.actions = ["contents": NSNull()]
        imageLayer.contentsGravity = .resize
        view.layer?.addSublayer(imageLayer)
        panel.contentView = view
    }

    var windowNumber: Int { panel.windowNumber }

    /// `pip` is the parked PiP window (nil hides the patch). Firefox also keeps a tiny companion
    /// window (~66×20, title "Window") glued to the PiP's top edge; small Firefox windows on the same
    /// level hugging the sliver are covered too.
    @MainActor
    func update(pip: SCWindow?, content: SCShareableContent, excluding ours: [Int]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        guard let pip,
              let display = content.displays.first(where: { $0.frame.intersects(pip.frame) }) else {
            await stop()
            return
        }
        let sliver = pip.frame.intersection(display.frame)
        let companions = content.windows.filter { w in
            w.windowID != pip.windowID && w.isOnScreen
                && w.owningApplication?.processID == pip.owningApplication?.processID
                && w.windowLayer == pip.windowLayer
                && w.frame.width <= 200 && w.frame.height <= 100
                && w.frame.intersects(sliver.insetBy(dx: -40, dy: -40))
        }
        var rect = sliver
        for w in companions {
            let visible = w.frame.intersection(display.frame)
            if !visible.isNull { rect = rect.union(visible) }
        }
        rect = rect.integral
        let hiddenIDs = Set([pip.windowID] + companions.map(\.windowID))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              rect.width * rect.height < 200 * 200 else {   // only ever cover a small sliver
            await stop()
            return
        }
        if stream != nil, rect == coveredRect, hiddenIDs == coveredWindows { return }
        await stop()

        // Place the patch exactly over the sliver.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height),
                       display: false)
        imageLayer.frame = CGRect(origin: .zero, size: rect.size)
        panel.orderFrontRegardless()

        let excluded = content.windows.filter { hiddenIDs.contains($0.windowID) || ours.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
                                   width: rect.width, height: rect.height)
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(2, Int(rect.width * scale))
        config.height = max(2, Int(rect.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        do {
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            coveredRect = rect
            coveredWindows = hiddenIDs
            Log.info("patch: covering \(Int(rect.width))x\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY)) (\(hiddenIDs.count) Firefox window(s))")
        } catch {
            Log.info("patch: start failed: \(error.localizedDescription)")
            panel.orderOut(nil)
        }
    }

    @MainActor
    func stop() async {
        panel.orderOut(nil)
        imageLayer.contents = nil
        coveredRect = .null
        coveredWindows = []
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        Log.info("patch: stopped")
    }

    /// Synchronous teardown for quit.
    @MainActor
    func hideNow() { panel.orderOut(nil) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sampleBuffer.imageBuffer,
              let ref = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let surface = unsafeBitCast(ref, to: IOSurface.self)
        DispatchQueue.main.async { [imageLayer] in imageLayer.contents = surface }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("patch: stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if self.stream === stream {
                self.stream = nil
                self.coveredRect = .null
                self.panel.orderOut(nil)
            }
        }
    }
}

private final class PatchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
