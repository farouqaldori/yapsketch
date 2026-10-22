import AppKit
import QuartzCore

/// Show and hide animations for the floating panels, like macOS's own HUDs. Showing a panel
/// that's on its way out brings it straight back. Main thread only.
enum PanelMotion {
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    private static var leaving: [ObjectIdentifier: Int] = [:]
    /// Where a leaving panel was, to come back to.
    private static var resting: [ObjectIdentifier: CGPoint] = [:]
    private static var generation = 0

    static func isLeaving(_ panel: NSWindow) -> Bool { leaving[ObjectIdentifier(panel)] != nil }

    /// Shows `panel` at `origin` (or where it is, or where it was before leaving).
    static func show(_ panel: NSWindow, at origin: CGPoint? = nil, rise: CGFloat = 10, duration: Double = 0.26) {
        let id = ObjectIdentifier(panel)
        let wasLeaving = leaving.removeValue(forKey: id) != nil
        let rest = origin ?? resting.removeValue(forKey: id) ?? panel.frame.origin
        if panel.isVisible, !wasLeaving {
            if origin != nil { panel.setFrameOrigin(rest) }
            return
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrameOrigin(CGPoint(x: rest.x, y: rest.y - rise))
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = easeOut
            panel.animator().alphaValue = 1
            panel.animator().setFrame(CGRect(origin: rest, size: panel.frame.size), display: true)
        }
    }

    /// Fades `panel` out and orders it out; `done` runs once it's gone (not if it was shown
    /// again on the way out).
    static func hide(_ panel: NSWindow, drop: CGFloat = 6, duration: Double = 0.18, done: (() -> Void)? = nil) {
        let id = ObjectIdentifier(panel)
        guard panel.isVisible, leaving[id] == nil else {
            if !panel.isVisible { done?() }
            return
        }
        generation += 1
        let mine = generation
        leaving[id] = mine
        let rest = panel.frame.origin
        resting[id] = rest
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = easeIn
            panel.animator().alphaValue = 0
            panel.animator().setFrame(CGRect(origin: CGPoint(x: rest.x, y: rest.y - drop), size: panel.frame.size), display: true)
        }) {
            guard leaving[id] == mine else { return }
            leaving[id] = nil
            resting[id] = nil
            panel.orderOut(nil)
            panel.setFrameOrigin(rest)
            panel.alphaValue = 1
            done?()
        }
    }

    /// Brings back shown panels stranded on one Space. The window server once forgot that
    /// YapSketch's panels join every Space, leaving a recording's toolbar on a desktop no one
    /// was looking at for hours. Setting the collection behavior again restores it; ordering
    /// the panel in again doesn't.
    static func rejoinAllSpaces() {
        for window in NSApp.windows
        where window.isVisible && window.collectionBehavior.contains(.canJoinAllSpaces) && !window.isOnActiveSpace {
            let behavior = window.collectionBehavior
            window.collectionBehavior = []
            window.collectionBehavior = behavior
            window.orderFrontRegardless()
            Log.info("panel was stuck on another Space, brought back: \(type(of: window)) \(window.frame.size)")
        }
    }

    /// A small spring: `view` grows in from `from` of its size, about its centre.
    static func pop(_ view: NSView, from: CGFloat = 0.3) {
        guard let layer = view.layer else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = from
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 14
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        layer.add(fade, forKey: "popFade")
    }

    /// The next change to `view`'s contents and its subviews' crossfades instead of jumping.
    static func crossfade(_ view: NSView, duration: Double = 0.2) {
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        t.timingFunction = easeOut
        view.layer?.add(t, forKey: "crossfade")
    }
}
