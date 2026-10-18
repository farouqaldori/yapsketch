import AppKit

/// The small pill that takes the toolbar's place once a recording stops: just a spinner while
/// the report is made, then "Copied" (or ready) with Copy.
/// Kept out of recordings, like the toolbar.
final class StatusPill {
    var onCopy: (() -> Void)?

    private let panel: NSPanel
    private let view = PillView()
    private var hideWork: DispatchWorkItem?
    /// A problem's button ("Try Again"), in Copy's place.
    private var fix: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: PillView.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none
        panel.contentView = view
        view.copy.action = { [weak self] in
            guard let self else { return }
            if let fix = self.fix {
                self.hide()
                fix()
            } else {
                self.onCopy?()
                self.flash("Copied")
            }
        }
        view.close.action = { [weak self] in self?.hide() }
    }

    #if DEBUG
    /// For the snapshots.
    var debugPanel: NSPanel { panel }
    #endif

    /// Working on it: a spinner. `anchor`: the toolbar's frame, to take its place (the toolbar
    /// seems to fold into the pill).
    func working(anchor: CGRect? = nil) {
        hideWork?.cancel()
        if panel.isVisible { PanelMotion.crossfade(view) }
        fix = nil
        view.set(text: "", busy: true, actions: false)
        place(anchor: anchor)
    }

    /// Done: `text` and the Copy button, gone by itself after a while.
    func done(_ text: String) {
        fix = nil
        view.copy.title = "Copy"
        show(text, problem: false, for: 10)
    }

    /// Something went wrong: `text` with a coral mark, and `button` to put it right when
    /// there's something to do. Stays a little longer than done.
    func problem(_ text: String, button: String? = nil, action: (() -> Void)? = nil) {
        fix = action
        view.copy.title = button ?? ""
        show(text, problem: true, for: 15)
    }

    private func show(_ text: String, problem: Bool, for seconds: Double) {
        let wasVisible = panel.isVisible
        if wasVisible { PanelMotion.crossfade(view, duration: 0.25) }
        view.set(text: text, busy: false, actions: true, problem: problem)
        place(anchor: nil)
        view.layoutSubtreeIfNeeded()
        if wasVisible { view.popTick() }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        HoverTip.shared.hide()
        hideWork?.cancel()
        PanelMotion.hide(panel) { [view] in view.set(text: "", busy: false, actions: false) }
    }

    private func flash(_ text: String) {
        PanelMotion.crossfade(view)
        view.set(text: text, busy: false, actions: true)
        place(anchor: nil)
    }

    /// Centred where the toolbar was (or at the bottom of the screen): small round the
    /// spinner, wide enough for the words and buttons when done.
    private func place(anchor: CGRect?) {
        let size = CGSize(width: view.isBusy ? PillView.busyWidth : view.fittingWidth, height: PillView.height)
        let current = panel.isVisible ? panel.frame : nil
        let midX: CGFloat
        let minY: CGFloat
        if let a = anchor, a.width > 0 {
            midX = a.midX
            // On the toolbar's bottom edge: where the dictation pill sits too.
            minY = a.minY
        } else if let c = current {
            midX = c.midX
            minY = c.minY
        } else {
            let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            midX = f.midX
            minY = f.minY + 24
        }
        let target = CGRect(x: midX - size.width / 2, y: minY, width: size.width, height: size.height)
        view.needsLayout = true
        if panel.isVisible, !PanelMotion.isLeaving(panel) {
            // Spinner to words: widens about its middle.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.34
                ctx.timingFunction = PanelMotion.easeOut
                panel.animator().setFrame(target, display: true)
            }
        } else if let a = anchor, a.width > 0, !panel.isVisible {
            // Out of the toolbar: as wide as it, narrowing to the pill as it fades in.
            panel.setFrame(CGRect(x: a.midX - a.width / 2, y: minY, width: a.width, height: size.height), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.38
                ctx.timingFunction = PanelMotion.easeOut
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: false)
            PanelMotion.show(panel, at: target.origin)
        }
    }
}

/// Near-black, like the toolbar it replaces: a spinner while working, a green tick when done.
private final class PillView: NSView {
    static let width: CGFloat = 340
    static let busyWidth: CGFloat = 60
    static let height: CGFloat = 44

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let tick = NSImageView(image: PillView.tickImage)
    let copy = TextButton(title: "Copy", tip: "Copy the instructions for your agent")
    let close = TextButton(title: "×", tip: "Dismiss")
    private var busy = false, actions = false
    var isBusy: Bool { busy }

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        label.font = Brand.ui(12.5, .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        tick.wantsLayer = true
        for v in [spinner, tick, label, copy, close] as [NSView] { addSubview(v) }
    }

    /// The tick springs in.
    func popTick() { if !tick.isHidden { PanelMotion.pop(tick) } }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, busy: Bool, actions: Bool, problem: Bool = false) {
        self.busy = busy
        self.actions = actions
        label.stringValue = text
        tick.image = problem ? Self.problemImage : Self.tickImage
        tick.isHidden = busy || !actions
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        close.isHidden = !actions
        copy.isHidden = !actions || copy.title.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    /// Wide enough for the words and buttons (up to a point, then the words are cut short).
    var fittingWidth: CGFloat {
        var w = 14 + (tick.isHidden ? 0 : 26) + ceil(label.intrinsicContentSize.width) + 22
        if actions { w += close.width + 4 + (copy.isHidden ? 0 : copy.width + 12) }
        return min(560, max(Self.width, w))
    }

    // Spinner or tick · text · buttons pinned to the right edge.
    override func layout() {
        super.layout()
        var x: CGFloat = 14
        let h = bounds.height
        label.isHidden = busy
        if busy {
            spinner.frame = CGRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
            return
        } else if !tick.isHidden {
            tick.frame = CGRect(x: x, y: (h - 18) / 2, width: 18, height: 18)
            x += 26
        }
        var right = bounds.width - 10
        if actions {
            for (b, gap) in [(close, 4.0), (copy, 12.0)] as [(TextButton, CGFloat)] where !b.isHidden {
                right -= b.width
                b.frame = CGRect(x: right, y: (h - 24) / 2, width: b.width, height: 24)
                right -= gap
            }
        }
        let textH = label.intrinsicContentSize.height
        label.frame = CGRect(x: x, y: (h - textH) / 2, width: max(0, right - x), height: textH)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Brand.chrome.setFill()
        path.fill()
        Brand.chromeEdge.setStroke()
        path.stroke()
    }

    /// Done: a white tick on a green dot.
    static let tickImage = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { r in
        Brand.doneOnInk.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75)).fill()
        let t = NSBezierPath()
        t.move(to: CGPoint(x: 5.25, y: 9.3))
        t.line(to: CGPoint(x: 7.7, y: 11.75))
        t.line(to: CGPoint(x: 12.9, y: 6.75))
        t.lineWidth = 2
        t.lineCapStyle = .round
        t.lineJoinStyle = .round
        NSColor.white.setStroke()
        t.stroke()
        return true
    }

    /// A problem: a white bar on a coral dot.
    static let problemImage = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { r in
        Brand.coral.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75)).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: 8, y: 4.5, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(ovalIn: CGRect(x: 8, y: 12, width: 2, height: 2)).fill()
        return true
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

/// A small text button for the pill.
private final class TextButton: NSView {
    var action: (() -> Void)?
    var title: String {
        didSet {
            tip = title == "Copy" ? "Copy the instructions for your agent" : title
            setAccessibilityLabel(tip)
            needsDisplay = true
        }
    }
    private var tip: String
    private var hovering = false { didSet { needsDisplay = true } }
    private static let font = Brand.ui(12, .semibold)

    init(title: String, tip: String) {
        self.title = title
        self.tip = tip
        super.init(frame: .zero)
        setAccessibilityLabel(tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    var width: CGFloat {
        title == "×" ? 24 : ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 20
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        HoverTip.shared.schedule(tip, for: self)
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        HoverTip.shared.leave()
    }
    override func mouseDown(with event: NSEvent) { HoverTip.shared.hide() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if title != "×" || hovering {
            NSColor(white: 1, alpha: hovering ? 0.22 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor(white: 1, alpha: title == "×" ? 0.6 : 0.95),
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
