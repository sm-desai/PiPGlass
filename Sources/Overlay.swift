import AppKit
import QuartzCore

/// Borderless, translucent, always-on-top panel that shows captured frames.
final class OverlayPanel: NSPanel {
    let videoView = VideoView()
    /// Called after the user finishes moving or resizing the panel.
    var onFrameCommitted: (() -> Void)?

    /// Source width / height.
    var aspect: CGFloat = 16.0 / 9.0 {
        didSet { contentAspectRatio = NSSize(width: aspect, height: 1) }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above ordinary floating windows (including Firefox's own PiP window).
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isMovable = false // we drag manually so the drag/resize zones don't fight
        animationBehavior = .none
        minSize = NSSize(width: 120, height: 68)
        contentView = videoView
        videoView.panel = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var clickThrough: Bool = true {
        didSet {
            ignoresMouseEvents = clickThrough
            videoView.showsChrome = !clickThrough
        }
    }

    /// Resize to `width` keeping the aspect ratio, anchored at the top-left corner.
    func applyAspect(keepingWidth width: CGFloat) {
        var f = frame
        let newHeight = (width / aspect).rounded()
        f.origin.y += f.height - newHeight
        f.size = NSSize(width: width.rounded(), height: newHeight)
        setFrame(f, display: true)
    }
}

/// Layer-backed view whose layer contents are the latest IOSurface; also handles drag + resize.
final class VideoView: NSView {
    weak var panel: OverlayPanel?

    private let videoLayer = CALayer()
    private let borderLayer = CALayer()
    private let gripLayer = CAShapeLayer()
    private let hudLayer = CATextLayer()
    private var hudHide: DispatchWorkItem?

    var showsChrome = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderLayer.isHidden = !showsChrome
            gripLayer.isHidden = !showsChrome
            CATransaction.commit()
            window?.invalidateCursorRects(for: self)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.clear.cgColor

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        videoLayer.magnificationFilter = .linear
        videoLayer.minificationFilter = .linear
        layer?.addSublayer(videoLayer)

        borderLayer.borderColor = NSColor.controlAccentColor.cgColor
        borderLayer.borderWidth = 2
        borderLayer.isHidden = true
        borderLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(borderLayer)

        gripLayer.fillColor = NSColor.white.withAlphaComponent(0.85).cgColor
        gripLayer.strokeColor = NSColor.black.withAlphaComponent(0.5).cgColor
        gripLayer.lineWidth = 1
        gripLayer.isHidden = true
        gripLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(gripLayer)

        hudLayer.fontSize = 15
        hudLayer.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        hudLayer.foregroundColor = NSColor.white.cgColor
        hudLayer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        hudLayer.cornerRadius = 7
        hudLayer.alignmentMode = .center
        hudLayer.contentsScale = 2
        hudLayer.opacity = 0
        layer?.addSublayer(hudLayer)
    }

    /// Briefly shows `text` centred on the overlay (feedback for hotkeys / menu changes).
    func flash(_ text: String) {
        let width = min(bounds.width - 16, CGFloat(text.count) * 9 + 28)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hudLayer.contentsScale = window?.backingScaleFactor ?? 2
        hudLayer.string = text
        hudLayer.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - 28) / 2, width: width, height: 28)
        hudLayer.opacity = 1
        CATransaction.commit()
        hudHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            self?.hudLayer.opacity = 0
            CATransaction.commit()
        }
        hudHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        borderLayer.frame = bounds
        gripLayer.frame = bounds
        let g = Self.gripSize
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.maxX - 3, y: 3))
        path.addLine(to: CGPoint(x: bounds.maxX - 3, y: 3 + g))
        path.addLine(to: CGPoint(x: bounds.maxX - 3 - g, y: 3))
        path.closeSubpath()
        gripLayer.path = path
        CATransaction.commit()
    }

    func display(surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = surface
        CATransaction.commit()
    }

    func clear() {
        videoLayer.contents = nil
    }

    // MARK: Drag & resize (only reachable when click-through is off)

    private static let gripSize: CGFloat = 14
    private static let edge: CGFloat = 10

    private enum Mode { case move, resize(left: Bool, bottom: Bool, horizontal: Bool, vertical: Bool) }
    private var mode: Mode = .move
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard showsChrome else { return }
        let e = Self.edge
        addCursorRect(NSRect(x: 0, y: 0, width: e, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - e, y: 0, width: e, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - e, width: bounds.width, height: e), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: bounds.maxX - 24, y: 0, width: 24, height: 24), cursor: .crosshair)
        addCursorRect(bounds.insetBy(dx: e, dy: e), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
        let e = Self.edge
        let nearLeft = p.x < e, nearRight = p.x > bounds.maxX - e
        let nearBottom = p.y < e, nearTop = p.y > bounds.maxY - e
        let inGrip = p.x > bounds.maxX - 24 && p.y < 24
        if inGrip {
            mode = .resize(left: false, bottom: true, horizontal: true, vertical: true)
        } else if nearLeft || nearRight || nearBottom || nearTop {
            mode = .resize(left: nearLeft, bottom: nearBottom,
                           horizontal: nearLeft || nearRight, vertical: nearTop || nearBottom)
        } else {
            mode = .move
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        switch mode {
        case .move:
            panel.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
        case let .resize(left, bottom, horizontal, vertical):
            let aspect = panel.aspect
            let wFromX = startFrame.width + (left ? -dx : dx)
            let wFromY = (startFrame.height + (bottom ? -dy : dy)) * aspect
            var width: CGFloat
            switch (horizontal, vertical) {
            case (true, true): width = max(wFromX, wFromY)
            case (true, false): width = wFromX
            default: width = wFromY
            }
            width = max(panel.minSize.width, min(width, 8000)).rounded()
            let height = (width / aspect).rounded()
            var f = startFrame
            f.size = NSSize(width: width, height: height)
            f.origin.x = left ? startFrame.maxX - width : startFrame.minX
            f.origin.y = bottom ? startFrame.maxY - height : startFrame.minY
            panel.setFrame(f, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if panel?.frame != startFrame { panel?.onFrameCommitted?() }
    }
}
