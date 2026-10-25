import ScreenCaptureKit
import CoreMedia
import IOSurface
import CoreImage

/// Captures one window with ScreenCaptureKit and hands each new frame's IOSurface to `onFrame`.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let maxFPS: Int32 = 30

    /// Called on the capture queue for each frame whose content changed.
    var onFrame: ((IOSurface) -> Void)?
    /// Called on the main queue when the stream stops on its own (e.g. the window closed).
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "pipglass.capture", qos: .userInteractive)
    private(set) var pixelSize: CGSize = .zero

    // Frame statistics, touched only on `queue`.
    private var framesSinceReport = 0
    private var lastReport = Date()
    private var lastFrameAt: Date?
    private var lastSurface: IOSurface?

    var isRunning: Bool { stream != nil }

    func start(window: SCWindow, pixelSize: CGSize) async throws {
        await stop()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = Self.configuration(pixelSize: pixelSize)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync { framesSinceReport = 0; lastReport = Date(); lastFrameAt = nil }
        try await stream.startCapture()
        self.stream = stream
        self.pixelSize = CGSize(width: config.width, height: config.height)
        Log.info("capture: started window \(window.windowID) at \(config.width)x\(config.height)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() } catch { /* already stopped */ }
        Log.info("capture: stopped")
    }

    func update(pixelSize: CGSize) {
        guard let stream else { return }
        let config = Self.configuration(pixelSize: pixelSize)
        let newSize = CGSize(width: config.width, height: config.height)
        guard newSize != self.pixelSize else { return }
        self.pixelSize = newSize
        stream.updateConfiguration(config) { error in
            if let error { Log.info("capture: updateConfiguration failed: \(error.localizedDescription)") }
            else { Log.info("capture: resized to \(config.width)x\(config.height)") }
        }
    }

    /// Seconds since the last changed frame arrived (nil if none yet).
    func secondsSinceLastFrame() -> TimeInterval? {
        queue.sync { lastFrameAt.map { Date().timeIntervalSince($0) } }
    }

    /// Copy of the most recent frame (for the debug snapshot).
    func lastFrameImage() -> CGImage? {
        queue.sync {
            guard let surface = lastSurface else { return nil }
            let ci = CIImage(ioSurface: surface)
            return CIContext().createCGImage(ci, from: ci.extent)
        }
    }

    private static func configuration(pixelSize: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        // Even dimensions keep the scaler happy.
        c.width = max(16, Int(pixelSize.width.rounded()) & ~1)
        c.height = max(16, Int(pixelSize.height.rounded()) & ~1)
        c.minimumFrameInterval = CMTime(value: 1, timescale: maxFPS)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.queueDepth = 4
        c.showsCursor = false
        c.capturesAudio = false
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.ignoreShadowsSingleWindow = true
        c.backgroundColor = .clear
        return c
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        let now = Date()
        lastFrameAt = now
        framesSinceReport += 1
        let elapsed = now.timeIntervalSince(lastReport)
        if elapsed >= 10 {
            Log.info(String(format: "capture: %.1f fps (changed frames) over %.0fs", Double(framesSinceReport) / elapsed, elapsed))
            framesSinceReport = 0
            lastReport = now
        }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        lastSurface = surface
        onFrame?(surface)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture: stream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.stream = nil
            self.onStopped?(error)
        }
    }
}
