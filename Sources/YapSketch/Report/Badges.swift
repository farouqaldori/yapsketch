import AppKit

/// A point's number on its picture: a coral badge next to its marks, or in the corner.
enum Badges {
    static let radius = 14.0
    static let corner = CGPoint(x: radius + 10, y: radius + 10)

    /// Where a picture's badges go, in screen points: at the top left of each group of its marks
    /// that touch or nearly touch (a circle in two strokes, an arrow at a box, get one).
    static func spots(_ boxes: [CGRect], display: CGSize) -> [CGPoint] {
        var groups: [CGRect] = []
        for b in boxes {
            var g = b
            while let i = groups.firstIndex(where: { $0.insetBy(dx: -24, dy: -24).intersects(g) }) { g = g.union(groups.remove(at: i)) }
            groups.append(g)
        }
        let r = radius + 2
        return groups.map {
            CGPoint(x: min(max(r, $0.minX - 4), display.width - r), y: min(max(r, $0.minY - 4), display.height - r))
        }
    }

    /// `image` with badge `n` at each spot (screen points).
    static func stamp(_ n: Int, at spots: [CGPoint], on image: CGImage, display: CGSize) -> CGImage? {
        let w = image.width
        let h = image.height
        let s = Double(w) / display.width
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16 * s, weight: .heavy), .foregroundColor: NSColor.black]
        let label = "\(n)" as NSString
        let size = label.size(withAttributes: attrs)
        let r = radius * s
        for p in spots {
            // The context's rows run bottom-up.
            let c = CGPoint(x: p.x * s, y: Double(h) - p.y * s)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3 * s, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setFillColor(Brand.coral.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
