import AppKit
import QuartzCore

enum DrawTool: String, CaseIterable {
    case pen, arrow, rect, highlight, text

    var key: String {
        switch self {
        case .pen: "p"
        case .arrow: "a"
        case .rect: "r"
        case .highlight: "h"
        case .text: "t"
        }
    }
}

struct InkColor {
    let name: String
    let color: NSColor

    static let all: [InkColor] = [
        InkColor(name: "red", color: Brand.coral),
        InkColor(name: "yellow", color: Brand.sun),
        InkColor(name: "green", color: Brand.markGreen),
        InkColor(name: "blue", color: Brand.markBlue),
        InkColor(name: "white", color: .white),
    ]
}

/// A finished annotation, reported in display coordinates (points, top-left origin).
struct AnnotationInfo {
    let tool: DrawTool
    let color: String
    let bbox: CGRect
    let text: String?
    /// Where an arrow points.
    var tip: CGPoint? = nil
    /// Which stroke it is, so the log can say when it fades.
    var id = 0
    /// How long the stroke took, in seconds.
    var duration: Double = 0
}

/// Full-screen transparent canvas. Draws persistent annotations; accepts mouse
/// input only while draw mode is on (the window ignores mouse events otherwise).
final class CanvasView: NSView, NSTextFieldDelegate {
    private enum Shape {
        case stroke([CGPoint], NSColor, CGFloat, CGFloat)  // points, color, width, alpha
        case arrow(CGPoint, CGPoint, NSColor)
        case rect(CGRect, NSColor)
        case text(String, CGPoint, NSColor)
    }

    var tool: DrawTool = .pen { didSet { onStateChange?() } }
    /// Scales every stroke (menu → Ink Size): 0.7 thin, 1 medium, 1.5 thick.
    var inkSize: CGFloat = 0.7  // thin by default
    private var penWidth: CGFloat { 3 * inkSize }  // ≈ 5.5 pt ink at medium (tldraw's medium pen)
    private var highlightWidth: CGFloat { 18 * inkSize }
    private var lineWidth: CGFloat { 3.5 * inkSize }  // arrows
    private var boxWidth: CGFloat { 3 * inkSize }
    private var headSize: CGFloat { max(12, 16 * inkSize) }
    var colorIndex = 0 { didSet { onStateChange?() } }
    var ink: InkColor { InkColor.all[colorIndex] }

    var onAnnotation: ((AnnotationInfo) -> Void)?
    var onClear: (() -> Void)?
    /// A temporary stroke faded away (its id).
    var onErase: ((Int) -> Void)?
    var onExit: (() -> Void)?
    var onStateChange: (() -> Void)?

    private var shapes: [Shape] = []
    /// Each shape's id (parallel to `shapes`).
    private var ids: [Int] = []
    private var nextID = 1
    /// When each shape disappears (parallel to `shapes`); nil = stays until cleared.
    private var expiries: [CFTimeInterval?] = []

    /// Temporary ink: new strokes fade out on their own after `fadeAfter` seconds.
    var fading = false { didSet { onStateChange?() } }
    var fadeAfter: Double = 3
    private let fadeDuration: Double = 0.6
    private var fadeTimer: Timer?

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
    private var current: Shape?
    private var dragStart: CGPoint = .zero
    private var dragStartTime: CFTimeInterval = 0
    private var editor: NSTextField?

    /// The stroke being drawn, rendered by the GPU so it follows the mouse without
    /// repainting the whole screen; it joins the canvas when the mouse is released.
    private let liveLayer = CAShapeLayer()
    private let liveHead = CAShapeLayer()
    private(set) var isDragging = false
    var onStrokeEnded: (() -> Void)?
    /// Accepting the mouse right now (draw mode); shows the crosshair.
    var interactive = false { didSet { window?.invalidateCursorRects(for: self) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [liveLayer, liveHead] {
            l.lineCap = .round
            l.lineJoin = .round
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.6
            l.shadowRadius = 2
            l.shadowOffset = .zero
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    // A crosshair while drawing, even though YapSketch isn't the active app.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) {
        if interactive { NSCursor.crosshair.set() } else { super.cursorUpdate(with: event) }
    }

    var hasContent: Bool { !shapes.isEmpty }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let now = CACurrentMediaTime()
        for i in shapes.indices {
            ctx.saveGState()
            ctx.setAlpha(alpha(i, now))
            draw(shapes[i], in: ctx)
            ctx.restoreGState()
        }
    }

    private func draw(_ shape: Shape, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // A soft dark halo keeps ink readable on any background.
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.6).cgColor)

        switch shape {
        case .stroke(let points, let color, let width, let alpha):
            guard !points.isEmpty else { return }
            if alpha < 1 { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.addPath(Self.inkPath(points, width: width, highlighter: alpha < 1, finished: true))
            ctx.fillPath()

        case .arrow(let from, let to, let color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(lineWidth)
            let (base, head) = Self.arrowHead(from: from, to: to, size: headSize)
            ctx.beginPath()
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            ctx.addPath(head)
            ctx.fillPath()

        case .rect(let r, let color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(boxWidth)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.strokePath()

        case .text(let string, let origin, let color):
            let attrs = Self.textAttributes(color)
            let size = (string as NSString).size(withAttributes: attrs)
            let box = CGRect(x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            (string as NSString).draw(at: origin, withAttributes: attrs)
        }
    }

    /// The ink outline for a freehand stroke (perfect-freehand, tldraw's stroke engine):
    /// pressure simulated from speed, tapering and smoothing, filled rather than stroked.
    static func inkPath(_ points: [CGPoint], width: CGFloat, highlighter: Bool, finished: Bool) -> CGPath {
        highlighter
            ? PerfectFreehand.path(points, PerfectFreehand.highlighter(width: Double(width), last: finished))
            : PerfectFreehand.path(points, PerfectFreehand.pen(width: Double(width), last: finished))
    }

    private static func arrowHead(from: CGPoint, to: CGPoint, size: CGFloat) -> (base: CGPoint, head: CGPath) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = CGMutablePath()
        head.move(to: to)
        head.addLine(to: CGPoint(x: to.x - cos(angle - .pi / 7) * size, y: to.y - sin(angle - .pi / 7) * size))
        head.addLine(to: CGPoint(x: to.x - cos(angle + .pi / 7) * size, y: to.y - sin(angle + .pi / 7) * size))
        head.closeSubpath()
        return (CGPoint(x: to.x - cos(angle) * size * 0.8, y: to.y - sin(angle) * size * 0.8), head)
    }

    private func updateLive() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        liveHead.path = nil
        switch current {
        case .stroke(let points, let color, let width, let alpha):
            liveLayer.fillColor = color.withAlphaComponent(alpha).cgColor
            liveLayer.strokeColor = nil
            liveLayer.shadowOpacity = alpha < 1 ? 0 : 0.6
            liveLayer.path = Self.inkPath(points, width: width, highlighter: alpha < 1, finished: false)
        case .arrow(let from, let to, let color):
            let (base, head) = Self.arrowHead(from: from, to: to, size: headSize)
            let line = CGMutablePath()
            line.move(to: from)
            line.addLine(to: base)
            liveLayer.strokeColor = color.cgColor
            liveLayer.fillColor = nil
            liveLayer.lineWidth = lineWidth
            liveLayer.shadowOpacity = 0.6
            liveLayer.path = line
            liveHead.fillColor = color.cgColor
            liveHead.strokeColor = nil
            liveHead.path = head
        case .rect(let r, let color):
            liveLayer.strokeColor = color.cgColor
            liveLayer.fillColor = nil
            liveLayer.lineWidth = boxWidth
            liveLayer.shadowOpacity = 0.6
            liveLayer.path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        default:
            liveLayer.path = nil
        }
    }

    static func textAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: color]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if editor != nil {
            commitText()
            return
        }
        dragStart = p
        dragStartTime = CACurrentMediaTime()
        switch tool {
        case .pen: current = .stroke([p], ink.color, penWidth, 1)
        case .highlight:
            // Real highlighters vanish on dark UIs; a lighter tint at higher opacity reads on both.
            let tint = ink.color.blended(withFraction: 0.35, of: .white) ?? ink.color
            current = .stroke([p], tint, highlightWidth, 0.55)
        case .arrow: current = .arrow(p, p, ink.color)
        case .rect: current = .rect(CGRect(origin: p, size: .zero), ink.color)
        case .text: beginText(at: p)
        }
        isDragging = current != nil
        updateLive()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch current {
        case .stroke(let points, let c, let w, let a):
            // Skip sub-pixel jitter; the curve does the rest.
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            current = .stroke(points + [p], c, w, a)
        case .arrow(let from, _, let c): current = .arrow(from, p, c)
        case .rect(_, let c): current = .rect(Self.rect(dragStart, p), c)
        default: break
        }
        updateLive()
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        defer { onStrokeEnded?() }
        guard let shape = current else { return }
        current = nil
        updateLive()
        // A dot or a twitch (a click while drawing) isn't a mark: no event.
        let extent = bounds(of: shape)
        if max(extent.width, extent.height) < 10 {
            needsDisplay = true
            return
        }
        let id = takeID()
        shapes.append(shape)
        ids.append(id)
        expiries.append(fading ? CACurrentMediaTime() + fadeAfter : nil)
        if fading { startFadeTimer() }
        needsDisplay = true
        var info = AnnotationInfo(tool: tool, color: ink.name, bbox: toDisplay(extent), text: nil)
        info.id = id
        info.duration = CACurrentMediaTime() - dragStartTime
        if case .arrow(_, let to, _) = shape { info.tip = CGPoint(x: to.x.rounded(), y: (bounds.height - to.y).rounded()) }
        onAnnotation?(info)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            onExit?()
            return
        }  // esc
        if event.keyCode == 51 || (event.modifierFlags.contains(.command) && key == "z") {
            undo()
            return
        }
        if let n = Int(key), (1...InkColor.all.count).contains(n) {
            colorIndex = n - 1
            return
        }
        if let t = DrawTool.allCases.first(where: { $0.key == key }) {
            tool = t
            return
        }
        if key == "c" {
            clear()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Temporary ink

    private func alpha(_ i: Int, _ now: CFTimeInterval) -> CGFloat {
        guard let end = expiries[i] else { return 1 }
        return CGFloat(max(0, min(1, (end - now) / fadeDuration)))
    }

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tickFade() }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func tickFade() {
        let now = CACurrentMediaTime()
        var gone: [Int] = []
        for i in shapes.indices.reversed() where (expiries[i] ?? .infinity) <= now {
            gone.append(ids[i])
            shapes.remove(at: i)
            ids.remove(at: i)
            expiries.remove(at: i)
        }
        gone.reversed().forEach { onErase?($0) }
        if expiries.allSatisfy({ $0 == nil }) {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        needsDisplay = true
        if !gone.isEmpty && shapes.isEmpty { onStateChange?() }
    }

    func undo() {
        guard !shapes.isEmpty else { return }
        shapes.removeLast()
        ids.removeLast()
        expiries.removeLast()
        needsDisplay = true
    }

    func clear() {
        cancelText()
        guard !shapes.isEmpty else { return }
        shapes.removeAll()
        ids.removeAll()
        expiries.removeAll()
        needsDisplay = true
        onClear?()
    }

    // MARK: Text tool

    private func beginText(at p: CGPoint) {
        let field = NSTextField(frame: CGRect(x: p.x - 8, y: p.y - 4, width: 420, height: 38))
        field.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        field.textColor = ink.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Type a note, ↩ to place"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = editor else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = CGPoint(x: field.frame.minX + 8, y: field.frame.minY + 4)
        let color = field.textColor ?? ink.color
        cancelText()
        guard !text.isEmpty else { return }
        let shape = Shape.text(text, origin, color)
        let id = takeID()
        shapes.append(shape)
        ids.append(id)
        expiries.append(fading ? CACurrentMediaTime() + fadeAfter : nil)
        if fading { startFadeTimer() }
        needsDisplay = true
        var info = AnnotationInfo(tool: .text, color: ink.name, bbox: toDisplay(bounds(of: shape)), text: text)
        info.id = id
        onAnnotation?(info)
    }

    private func cancelText() {
        editor?.removeFromSuperview()
        editor = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Geometry

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func bounds(of shape: Shape) -> CGRect {
        switch shape {
        case .stroke(let points, _, _, _):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .arrow(let a, let b, _): return Self.rect(a, b)
        case .rect(let r, _): return r
        case .text(let s, let o, let c):
            let size = (s as NSString).size(withAttributes: Self.textAttributes(c))
            return CGRect(origin: o, size: size)
        }
    }

    /// View coordinates (bottom-left origin) -> display coordinates (top-left origin).
    private func toDisplay(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height).integral
    }
}
