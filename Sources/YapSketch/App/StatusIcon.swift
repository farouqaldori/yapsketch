import AppKit

/// The app icon's mark for the menu bar, as a template image: the record dot, and the ribbon of
/// ink that wraps it and trails off into a squiggle (the same curve scripts/icon.py draws).
enum StatusIcon {
    static let image: NSImage = {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            // The icon's 1024 grid, fitted to the menu bar's height.
            let s = 0.0205
            let origin = CGPoint(x: 1.5 - 134 * s, y: 8 - 500 * s)
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }

            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: p(436, 500).x - 190 * s, y: p(436, 500).y - 190 * s, width: 380 * s, height: 380 * s)).fill()

            let ribbon = NSBezierPath()
            for i in 0...60 {
                let a = (-28 - Double(i) * 232 / 60) * .pi / 180
                let q = p(418 + 284 * cos(a), 500 + 284 * sin(a))
                i == 0 ? ribbon.move(to: q) : ribbon.line(to: q)
            }
            let end = (100.0) * .pi / 180
            let start = CGPoint(x: 418 + 284 * cos(end), y: 500 + 284 * sin(end))
            ribbon.curve(
                to: p(758, 586), controlPoint1: p(start.x + 150 * sin(end), start.y - 150 * cos(end)), controlPoint2: p(690, 640))
            ribbon.curve(to: p(800, 660), controlPoint1: p(800, 552), controlPoint2: p(812, 600))
            ribbon.curve(to: p(850, 712), controlPoint1: p(790, 712), controlPoint2: p(812, 748))
            ribbon.curve(to: p(968, 598), controlPoint1: p(890, 676), controlPoint2: p(930, 628))
            ribbon.lineWidth = 1.6
            ribbon.lineCapStyle = .round
            ribbon.lineJoinStyle = .round
            NSColor.black.setStroke()
            ribbon.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "YapSketch"
        return image
    }()
}
