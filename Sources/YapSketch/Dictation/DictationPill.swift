import AppKit

/// Never takes focus from the app being typed into.
@MainActor
final class DictationPill {
    private let panel: NSPanel
    private let box = NSView()
    private let liveDot = NSView()
    private let status = NSImageView()
    private let bars = LevelBars()
    private let label = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "0:00")
    private let spinner = NSProgressIndicator()
    private let cancel = NSButton()
    private var started = Date()
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    var onCancel: (() -> Void)?

    private static let listeningSize = CGSize(width: 420, height: 44)
    /// As tall as the recording's pill, and as far up the screen (see StatusPill).
    private static let height: CGFloat = 44

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.listeningSize), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.sharingType = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        box.wantsLayer = true
        box.layer?.backgroundColor = Brand.chrome.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Brand.chromeEdge.cgColor
        panel.contentView = box

        liveDot.wantsLayer = true
        liveDot.layer?.backgroundColor = Brand.coral.cgColor
        liveDot.layer?.cornerRadius = 4
        bars.color = Brand.coral
        label.font = Brand.ui(14)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        time.font = Brand.mono(11.5)
        time.textColor = Brand.onInkSoft
        time.alignment = .right

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        cancel.isBordered = false
        cancel.contentTintColor = Brand.onInkSoft
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        cancel.toolTip = "Cancel (esc)"
        status.wantsLayer = true
        for v in [liveDot, status, bars, label, time, spinner, cancel] as [NSView] { box.addSubview(v) }
    }

    #if DEBUG
    var debugPanel: NSPanel { panel }
    #endif

    @objc private func cancelTapped() { onCancel?() }

    func listening() {
        hideWork?.cancel()
        started = Date()
        bars.reset()
        time.stringValue = "0:00"
        text("")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = Int(Date().timeIntervalSince(self.started))
                self.time.stringValue = String(format: "%d:%02d", s / 60, s % 60)
            }
        }
        layout(.listening, animated: false)
        place()
        pulse(true)
        // Quick, so the first words aren't waiting on it.
        PanelMotion.show(panel, rise: 10, duration: 0.2)
    }

    func text(_ words: String) {
        let words = LiveWords.shown ? words : ""
        label.stringValue = words.isEmpty ? "Listening…" : words
        label.textColor = words.isEmpty ? Brand.onInkSoft : .white
    }

    func level(_ v: Float) { bars.push(v) }

    func working() {
        timer?.invalidate()
        pulse(false)
        PanelMotion.crossfade(box, duration: 0.22)
        label.stringValue = ""
        layout(.working)
        spinner.startAnimation(nil)
    }

    private func pulse(_ on: Bool) {
        guard on else { return liveDot.layer?.removeAnimation(forKey: "pulse") ?? () }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.35
        a.duration = 0.95
        a.autoreverses = true
        a.repeatCount = .infinity
        liveDot.layer?.add(a, forKey: "pulse")
    }

    func done(_ text: String, ok: Bool = true) {
        timer?.invalidate()
        spinner.stopAnimation(nil)
        pulse(false)
        PanelMotion.crossfade(box, duration: 0.24)
        label.stringValue = text
        label.textColor = .white
        status.image = ok ? Self.tick : Self.dot
        layout(.done)
        box.layoutSubtreeIfNeeded()
        if ok { PanelMotion.pop(status) }
        let h = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = h
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.1 : 1.6), execute: h)
    }

    func hide() {
        timer?.invalidate()
        pulse(false)
        spinner.stopAnimation(nil)
        PanelMotion.hide(panel, drop: 6, duration: 0.2)
    }

    private enum Phase { case listening, working, done }

    private func layout(_ phase: Phase, animated: Bool = true) {
        let listening = phase == .listening
        bars.isHidden = !listening
        time.isHidden = !listening
        cancel.isHidden = !listening
        liveDot.isHidden = !listening
        label.isHidden = phase == .working
        status.isHidden = phase != .done
        let textW = ceil(label.intrinsicContentSize.width)
        let size: CGSize =
            switch phase {
            case .listening: Self.listeningSize
            case .working: CGSize(width: 60, height: Self.height)
            case .done: CGSize(width: min(360, 36 + textW + 18), height: Self.height)
            }
        let h = size.height
        let labelH = label.intrinsicContentSize.height
        liveDot.frame = CGRect(x: 18, y: (h - 8) / 2, width: 8, height: 8)
        status.frame = CGRect(x: 10, y: (h - 18) / 2, width: 18, height: 18)
        var right = size.width - 10
        if listening {
            cancel.frame = CGRect(x: right - 24, y: (h - 24) / 2, width: 24, height: 24)
            right -= 28
            time.frame = CGRect(x: right - 34, y: (h - 15) / 2, width: 34, height: 15)
            right -= 42
            bars.frame = CGRect(x: right - 39, y: (h - 20) / 2, width: 39, height: 20)
            right -= 49
        } else if phase == .working {
            spinner.frame = CGRect(x: (size.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
        }
        let x: CGFloat = 36
        label.frame = CGRect(x: x, y: (h - labelH) / 2, width: max(0, right - x), height: labelH)
        box.layer?.cornerRadius = h / 2

        let old = panel.frame
        let midX = panel.isVisible ? old.midX : old.minX + size.width / 2
        let target = CGRect(x: midX - size.width / 2, y: old.minY, width: size.width, height: h)
        if animated, panel.isVisible, !PanelMotion.isLeaving(panel) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = PanelMotion.easeOut
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.minY + 24))
    }

    private static let tick = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { r in
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

    private static let dot = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { r in
        Brand.coral.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 4.5, dy: 4.5)).fill()
        return true
    }
}

private final class LevelBars: NSView {
    var color = NSColor.white
    private var levels = [Float](repeating: 0, count: 7)

    func reset() {
        levels = levels.map { _ in 0 }
        needsDisplay = true
    }

    func push(_ v: Float) {
        levels.removeFirst()
        levels.append(min(1, max(0, v)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = 3
        let gap = (bounds.width - w * CGFloat(levels.count)) / CGFloat(levels.count - 1)
        color.setFill()
        for (i, l) in levels.enumerated() {
            let h = max(4, bounds.height * CGFloat(l))
            let r = CGRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
