import AppKit
import QuartzCore

/// The ink layer's window: a non-activating panel, so drawing on it never takes focus from
/// the app being shown (its window stays active and live). It can still become key for
/// the drawing shortcuts and the text tool.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The transparent always-on-top layer over the recorded display: ink, click ripples and
/// keycast. It's captured with the screen, so these end up in the video
/// and the screenshots. Controls and the timer live in the mini player, which isn't.
final class OverlayController {
    let canvas: CanvasView
    private let window: OverlayWindow
    let screen: NSScreen
    private let root: NSView
    private let keycast = Pill(fontSize: 18, weight: .medium, mono: true)

    private var keycastHide: DispatchWorkItem?
    /// Draw mode switched on (toolbar tool or ⌃⌥D) until switched off.
    private(set) var sticky = false
    /// Draw mode while ⌃⌥ is held.
    private var holding = false
    private var releaseAfterStroke = false
    var drawMode: Bool { sticky || holding }
    var isRecording = false { didSet { updateVisibility() } }

    var onExitDrawMode: (() -> Void)?
    var onStateChange: (() -> Void)?

    init(screen: NSScreen) {
        self.screen = screen
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        root = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        canvas = CanvasView(frame: root.bounds)
        canvas.autoresizingMask = [.width, .height]
        root.addSubview(canvas)
        window.contentView = root

        keycast.isHidden = true
        root.addSubview(keycast)

        canvas.onExit = { [weak self] in self?.onExitDrawMode?() }
        canvas.onStrokeEnded = { [weak self] in
            guard let self, self.releaseAfterStroke else { return }
            self.releaseAfterStroke = false
            self.holding = false
            self.apply()
        }
        canvas.onStateChange = { [weak self] in
            self?.updateVisibility()
            self?.onStateChange?()
        }
    }

    private var size: CGSize { root.bounds.size }

    // MARK: Visibility

    private func updateVisibility() {
        let visible = isRecording || drawMode || canvas.hasContent
        if visible { window.orderFrontRegardless() } else { window.orderOut(nil) }
        layout()
    }

    // MARK: Keycast, ripples

    func showKeycast(_ text: String) {
        guard isRecording else { return }
        keycast.text = text
        keycast.isHidden = false
        layout()
        keycastHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.keycast.isHidden = true }
        keycastHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }

    /// Expanding ring at a click location (global Quartz coordinates -> local).
    func ripple(atLocal p: CGPoint) {
        guard isRecording, let layer = root.layer else { return }
        let viewPoint = CGPoint(x: p.x, y: size.height - p.y)
        let ring = CAShapeLayer()
        let r: CGFloat = 22
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        ring.position = viewPoint
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 3
        layer.addSublayer(ring)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.7
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    /// Brief flash in the corner, e.g. when live words aren't available.
    func flash(_ text: String) {
        keycast.text = text
        keycast.isHidden = false
        layout()
        keycastHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.keycast.isHidden = true }
        keycastHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    // MARK: Draw mode

    func setDrawMode(_ on: Bool) {
        guard on != sticky else { return }
        sticky = on
        apply()
    }

    /// Hold-to-draw: on while ⌃⌥ is held. Letting go mid-stroke finishes the stroke first.
    func setHolding(_ on: Bool) {
        if !on && canvas.isDragging {
            releaseAfterStroke = true
            return
        }
        guard on != holding else { return }
        holding = on
        apply()
    }

    private func apply() {
        let on = drawMode
        window.ignoresMouseEvents = !on
        canvas.interactive = on
        if on {
            window.orderFrontRegardless()
            // Keyboard shortcuts and the text tool need key focus; the panel takes it without
            // activating YapSketch, so the app underneath stays active.
            if sticky {
                window.makeKey()
                window.makeFirstResponder(canvas)
            }
            NSCursor.crosshair.set()
        } else {
            if window.isKeyWindow { window.resignKey() }
            NSCursor.arrow.set()
        }
        updateVisibility()
        onStateChange?()
    }

    func clear() {
        canvas.clear()
        updateVisibility()
    }

    // MARK: Layout

    private func layout() {
        let margin: CGFloat = 16
        keycast.sizeToFitContent(maxWidth: 600)
        keycast.setFrameOrigin(CGPoint(x: margin + 8, y: 24))
    }
}

/// Rounded label with a translucent background. Draws its own text so sizing is exact.
final class Pill: NSView {
    var fill = NSColor.black.withAlphaComponent(0.75) { didSet { needsDisplay = true } }
    var maxLines = 1
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var textColor: NSColor = .white { didSet { needsDisplay = true } }

    private let font: NSFont
    private let padH: CGFloat = 14
    private let padV: CGFloat = 7
    private var textRect: CGRect = .zero

    init(fontSize: CGFloat, weight: NSFont.Weight, mono: Bool = false) {
        font = mono ? .monospacedSystemFont(ofSize: fontSize, weight: weight) : .systemFont(ofSize: fontSize, weight: weight)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    private var attributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: textColor, .paragraphStyle: para]
    }

    func sizeToFitContent(maxWidth: CGFloat) {
        let limit = maxWidth - 2 * padH
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var r = (text as NSString).boundingRect(
            with: CGSize(width: limit, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        r.size.width = min(ceil(r.width) + 2, limit)
        r.size.height = min(ceil(r.height), lineHeight * CGFloat(maxLines) + 2)
        textRect = CGRect(x: padH, y: padV, width: r.width, height: r.height)
        setFrameSize(CGSize(width: r.width + 2 * padH, height: r.height + 2 * padV))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes)
    }
}
