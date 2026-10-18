import AppKit
import QuartzCore

/// The floating recording toolbar, in ink: a pulsing coral dot, the mic's waveform, the clock
/// and the words as they're heard; below, the drawing tools, colors, temporary ink, undo,
/// clear, discard and stop. It's excluded from the recording, so it never shows up in screenshots.
final class MiniPlayer {
    var onTool: ((DrawTool?) -> Void)?  // nil = pointer (stop drawing)
    var onColor: ((Int) -> Void)?
    var onToggleFade: (() -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onRecordToggle: (() -> Void)?
    var onDiscard: (() -> Void)?

    let panel: NSPanel
    private let view: PlayerView

    init() {
        view = PlayerView(frame: CGRect(x: 0, y: 0, width: PlayerView.width, height: PlayerView.height))
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // above the ink layer
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Keep the player out of screen recordings and screenshots.
        panel.sharingType = .none
        panel.contentView = view

        view.onTool = { [weak self] in self?.onTool?($0) }
        view.onColor = { [weak self] in self?.onColor?($0) }
        view.onToggleFade = { [weak self] in self?.onToggleFade?() }
        view.onUndo = { [weak self] in self?.onUndo?() }
        view.onClear = { [weak self] in self?.onClear?() }
        view.onRecordToggle = { [weak self] in self?.onRecordToggle?() }
        view.onDiscard = { [weak self] in self?.onDiscard?() }
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    func show(on screen: NSScreen) {
        let f = screen.visibleFrame
        PanelMotion.show(panel, at: panel.isVisible ? nil : CGPoint(x: f.midX - PlayerView.width / 2, y: f.minY + 24), rise: 14)
    }

    func hide() {
        HoverTip.shared.hide()
        PanelMotion.hide(panel, drop: 8)
    }

    func update(recording: Bool, elapsed: Double) { view.update(recording: recording, elapsed: elapsed) }
    /// The newest words heard, while recording.
    func setCaption(_ text: String) { view.setCaption(text) }
    /// The tooltips name the current shortcuts (they can be changed in Settings).
    func refreshTips() { view.refreshTips() }
    func push(level: Float) { view.push(level: level) }
    func sync(drawing: Bool, tool: DrawTool, color: Int, fading: Bool) {
        view.sync(drawing: drawing, tool: tool, color: color, fading: fading)
    }
}

private final class PlayerView: NSView {
    static let width: CGFloat = 548
    static let height: CGFloat = 80

    var onTool: ((DrawTool?) -> Void)?
    var onColor: ((Int) -> Void)?
    var onToggleFade: (() -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onRecordToggle: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let dot = CALayer()
    private let wave = WaveformView(frame: .zero)
    private let timer = NSTextField(labelWithString: "00:00")
    /// What you're saying, as it's heard (the newest words).
    private let caption = NSTextField(labelWithString: "")
    private var toolButtons: [(DrawTool?, PillButton)] = []
    private var colorButtons: [ColorDot] = []
    private let fadeButton = PillButton(symbol: "timer", tip: "Temporary ink: strokes fade after a few seconds")
    private let recordButton = PillButton(symbol: PillButton.stop, tip: "")
    private let discardButton = PillButton(symbol: "trash", tip: "Discard this recording")
    private var recording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        dot.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        dot.cornerRadius = 3.5
        dot.backgroundColor = Brand.coral.cgColor
        layer?.addSublayer(dot)

        wave.color = Brand.coral
        addSubview(wave)

        timer.font = Brand.mono(11)
        timer.textColor = Brand.onInkSoft
        addSubview(timer)

        caption.font = Brand.ui(12.5)
        caption.textColor = Brand.card
        caption.lineBreakMode = .byTruncatingHead
        addSubview(caption)

        let tools: [(DrawTool?, String, String)] = [
            (nil, "cursorarrow", "Stop drawing (esc). Hold ⌃⌥ and drag to draw anytime."),
            (.pen, "pencil", "Pen (P)"), (.arrow, "arrow.up.right", "Arrow (A)"),
            (.rect, "rectangle", "Box (R)"), (.highlight, "highlighter", "Highlighter (H)"),
            (.text, "textformat", "Text note (T)"),
        ]
        for (tool, symbol, tip) in tools {
            let b = PillButton(symbol: symbol, tip: tip)
            b.action = { [weak self] in self?.onTool?(tool) }
            toolButtons.append((tool, b))
            addSubview(b)
        }
        for (i, ink) in InkColor.all.enumerated() {
            let c = ColorDot(color: ink.color, tip: "\(ink.name.capitalized) (\(i + 1))")
            c.action = { [weak self] in self?.onColor?(i) }
            colorButtons.append(c)
            addSubview(c)
        }
        fadeButton.action = { [weak self] in self?.onToggleFade?() }
        addSubview(fadeButton)
        let undo = PillButton(symbol: "arrow.uturn.backward", tip: "Undo (⌫)")
        undo.action = { [weak self] in self?.onUndo?() }
        addSubview(undo)
        let clear = PillButton(symbol: PillButton.broom, tip: "")
        clearButton = clear
        clear.action = { [weak self] in self?.onClear?() }
        addSubview(clear)
        recordButton.action = { [weak self] in self?.onRecordToggle?() }
        addSubview(recordButton)
        discardButton.action = { [weak self] in self?.onDiscard?() }
        addSubview(discardButton)

        layoutRows(extra: [undo, clear])
        startPulse()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Above: dot · waveform · clock · what's being said.
    // Below: tools | colors · · · fade · undo · clear | discard · stop
    private func layoutRows(extra: [PillButton]) {
        let top = bounds.height - 10 - 11
        var x: CGFloat = 18
        dot.position = CGPoint(x: x + 3.5, y: top)
        x += 15
        wave.frame = CGRect(x: x, y: top - 8, width: 34, height: 16)
        x += 42
        timer.sizeToFit()
        timer.frame = CGRect(x: x, y: top - timer.frame.height / 2, width: 42, height: timer.frame.height)
        x += 48
        let captionH = caption.intrinsicContentSize.height
        caption.frame = CGRect(x: x, y: top - captionH / 2, width: bounds.width - 18 - x, height: captionH)

        let mid: CGFloat = 26
        x = 12
        for (_, b) in toolButtons {
            b.frame = CGRect(x: x, y: mid - 14, width: 28, height: 28)
            x += 32
        }
        x = separator(at: x)
        for c in colorButtons {
            c.frame = CGRect(x: x, y: mid - 11, width: 22, height: 22)
            x += 22
        }
        var right = bounds.width - 12 - 28
        recordButton.frame = CGRect(x: right, y: mid - 14, width: 28, height: 28)
        right -= 32
        discardButton.frame = CGRect(x: right, y: mid - 14, width: 28, height: 28)
        right = separator(at: right - 10) - 10
        for b in ([fadeButton] + extra).reversed() {
            right -= 28
            b.frame = CGRect(x: right, y: mid - 14, width: 28, height: 28)
            right -= 4
        }
    }

    private var separators: [CGFloat] = []

    private func separator(at x: CGFloat) -> CGFloat {
        separators.append(x + 4)
        return x + 10
    }

    /// Flat near-black with a faint edge.
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        Brand.chrome.setFill()
        shape.fill()
        Brand.chromeEdge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSColor.white.withAlphaComponent(0.12).setFill()
        for x in separators { NSRect(x: x, y: 26 - 9, width: 1, height: 18).fill(using: .sourceOver) }
    }

    private func startPulse() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.35
        a.duration = 0.95
        a.autoreverses = true
        a.repeatCount = .infinity
        dot.add(a, forKey: "pulse")
    }

    private var clearButton: PillButton?

    func refreshTips() {
        let rec = Shortcuts.get(.record).display
        recordButton.tip = recording ? "Stop recording (\(rec))" : "Start recording (\(rec))"
        clearButton?.tip = "Clear drawings (\(Shortcuts.get(.clear).display))"
    }

    func update(recording: Bool, elapsed: Double) {
        if recording != self.recording {
            self.recording = recording
            // Coral only while live.
            dot.backgroundColor = (recording ? Brand.coral : Brand.onInkSoft.withAlphaComponent(0.5)).cgColor
            wave.color = recording ? Brand.coral : Brand.onInkSoft.withAlphaComponent(0.4)
            if recording {
                startPulse()
            } else {
                dot.removeAnimation(forKey: "pulse")
                wave.reset()
            }
            recordButton.symbol = recording ? PillButton.stop : PillButton.record
            caption.stringValue = recording ? "" : "Drawing"
            caption.textColor = recording ? Brand.card : Brand.onInkSoft
            refreshTips()
            // Only a recording can be discarded; the button keeps its place either way.
            discardButton.isHidden = !recording
        }
        timer.stringValue = recording ? Fmt.clock(elapsed, decimals: false) : "--:--"
    }

    func setCaption(_ text: String) {
        guard recording, LiveWords.shown else { return }
        caption.stringValue = text
    }

    func push(level: Float) { wave.push(level) }

    func sync(drawing: Bool, tool: DrawTool, color: Int, fading: Bool) {
        for (t, b) in toolButtons { b.selected = drawing ? t == tool : t == nil }
        for (i, c) in colorButtons.enumerated() { c.selected = i == color }
        fadeButton.selected = fading
    }

    // The pill is draggable (isMovableByWindowBackground); clicks on controls still work.
    override var mouseDownCanMoveWindow: Bool { true }
}

/// A round, borderless icon button with an optional "selected" pill behind it.
private final class PillButton: NSView {
    /// Not SF Symbols: drawn here. There's no broom; stop and record are coral on a coral wash.
    static let broom = "yapsketch.broom"
    static let stop = "yapsketch.stop"
    static let record = "yapsketch.record"
    var action: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var symbol: String { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    /// Shown above the button on hover (HoverTip), and read by VoiceOver.
    var tip: String { didSet { setAccessibilityLabel(tip) } }

    init(symbol: String, tip: String) {
        self.symbol = symbol
        self.tip = tip
        super.init(frame: .zero)
        setAccessibilityLabel(tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
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
        if symbol == Self.stop || symbol == Self.record {
            Brand.coral.withAlphaComponent(hovering ? 0.32 : 0.22).setFill()
            NSBezierPath(ovalIn: bounds).fill()
            Brand.coral.setFill()
            let mark = CGRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)
            (symbol == Self.stop ? NSBezierPath(roundedRect: mark, xRadius: 2, yRadius: 2) : NSBezierPath(ovalIn: mark)).fill()
            return
        }
        if selected || hovering {
            NSColor.white.withAlphaComponent(selected ? 0.14 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let color = selected ? NSColor.white : Brand.onInkSoft
        if symbol == Self.broom {
            drawBroom(color)
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .regular).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config) else { return }
        img.draw(
            in: CGRect(
                x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2,
                width: img.size.width, height: img.size.height))
    }

    /// A broom, tilted: handle, binding and a fan of bristles, in a 16 pt box.
    private func drawBroom(_ color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: -.pi / 6)
        ctx.translateBy(x: -8, y: -8)
        color.setStroke()
        color.setFill()
        let handle = NSBezierPath()
        handle.move(to: CGPoint(x: 8, y: 15.5))
        handle.line(to: CGPoint(x: 8, y: 8.5))
        handle.lineWidth = 1.6
        handle.lineCapStyle = .round
        handle.stroke()
        NSBezierPath(roundedRect: CGRect(x: 5.6, y: 6.6, width: 4.8, height: 2), xRadius: 0.8, yRadius: 0.8).fill()
        let head = NSBezierPath()
        head.move(to: CGPoint(x: 6, y: 6.4))
        head.line(to: CGPoint(x: 10, y: 6.4))
        head.line(to: CGPoint(x: 12.6, y: 0.8))
        head.line(to: CGPoint(x: 3.4, y: 0.8))
        head.close()
        head.lineWidth = 1.3
        head.lineJoinStyle = .round
        head.stroke()
        for x: CGFloat in [6.4, 8, 9.6] {
            let bristle = NSBezierPath()
            bristle.move(to: CGPoint(x: x + (x - 8) * 0.1, y: 5.6))
            bristle.line(to: CGPoint(x: 8 + (x - 8) * 2.1, y: 1.6))
            bristle.lineWidth = 1
            bristle.lineCapStyle = .round
            bristle.stroke()
        }
        ctx.restoreGState()
    }
}

/// A color swatch; the selected one gets a ring.
private final class ColorDot: NSView {
    var action: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private let color: NSColor

    private let tip: String

    init(color: NSColor, tip: String) {
        self.color = color
        self.tip = tip
        super.init(frame: .zero)
        setAccessibilityLabel(tip)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { HoverTip.shared.schedule(tip, for: self) }
    override func mouseExited(with event: NSEvent) { HoverTip.shared.leave() }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { HoverTip.shared.hide() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    /// A small dot; the chosen one a little bigger, ringed in white with ink between.
    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = selected ? 10 : 9
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        if selected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: bounds.midX - 8.25, y: bounds.midY - 8.25, width: 16.5, height: 16.5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

/// A few reactive bars driven by the mic level.
private final class WaveformView: NSView {
    var color: NSColor = .white { didSet { needsDisplay = true } }
    private var levels = [Float](repeating: 0, count: 9)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        needsDisplay = true
    }

    func reset() {
        levels = [Float](repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 2
        let gap: CGFloat = 2
        color.setFill()
        for (i, v) in levels.enumerated() {
            let h = max(3, min(bounds.height, 3 + CGFloat(pow(v, 0.7)) * (bounds.height - 3)))
            let r = CGRect(x: CGFloat(i) * (barW + gap), y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
