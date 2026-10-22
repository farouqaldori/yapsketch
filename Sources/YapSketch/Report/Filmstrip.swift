import AppKit
import CoreGraphics

/// Frames side by side, for what one still can't show: `yapsketch frames` makes a contact sheet.
enum Filmstrip {
    /// Frames side by side, `columns` to a row, each with its time (minutes:seconds) under it;
    /// at most `maxWidth` pixels wide.
    static func sheet(_ tiles: [(t: Double, image: CGImage)], columns: Int, maxWidth: Double) -> CGImage? {
        guard let first = tiles.first?.image else { return nil }
        let gap = 6.0
        let label = 20.0
        let cols = max(1, min(columns, tiles.count))
        let rows = (tiles.count + cols - 1) / cols
        let tileW = min(Double(first.width), ((maxWidth - gap * Double(cols + 1)) / Double(cols)).rounded(.down))
        let tileH = (tileW * Double(first.height) / Double(first.width)).rounded()
        let width = Double(cols) * tileW + Double(cols + 1) * gap
        let height = gap + Double(rows) * (tileH + label) + Double(rows - 1) * gap
        guard
            let ctx = CGContext(
                data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.8, alpha: 1),
        ]
        for (i, tile) in tiles.enumerated() {
            let x = gap + Double(i % cols) * (tileW + gap)
            let top = gap + Double(i / cols) * (tileH + label + gap)
            let y = height - top - tileH
            ctx.draw(tile.image, in: CGRect(x: x, y: y, width: tileW, height: tileH))
            let m = Int(max(0, tile.t)) / 60
            (String(format: "%02d:%05.2f", m, max(0, tile.t) - Double(m * 60)) as NSString).draw(
                at: CGPoint(x: x + 2, y: y - label + 4), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
