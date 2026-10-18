import AppKit
import CoreGraphics

/// Frames side by side, for what one still can't show: a point about something moving gets
/// the stretch where the screen changed most, and `yapsketch frames` a contact sheet.
enum Filmstrip {
    struct Stretch {
        /// 6 times across one movement, from the last still frame before it to where it settled.
        let times: [Double]
        /// What changed, in screen points.
        let area: CGRect
    }

    /// The 1.6 s with the most change on screen (around the pointer aside) among `samples`
    /// (small frames, in order), leaving out the `skipping` moments; nil if nothing really changed.
    /// Within `near` only, when given (what the user circled is what they mean moves).
    static func busiest(
        _ samples: [(t: Double, g: ScreenDiff.Gray)], display: CGSize, pointer: (Double) -> CGPoint?, skipping: [ClosedRange<Double>],
        near: CGRect? = nil
    ) -> Stretch? {
        let inside = near.map { r in
            Set((0..<(64 * 40)).filter { i in
                let x = (Double(i % 64) + 0.5) / 64 * display.width
                let y = (Double(i / 64) + 0.5) / 40 * display.height
                return r.contains(CGPoint(x: x, y: y))
            })
        }
        var changes: [(t: Double, cells: [Int])] = []
        for (a, b) in zip(samples, samples.dropFirst()) where !skipping.contains(where: { $0.overlaps(a.t...b.t) }) {
            let around = [pointer(a.t), pointer(b.t)].compactMap { $0 }
            var cells = ScreenDiff.changed(a.g, b.g, ignoring: LiveFrames.fineCells(around: around, display: display), cols: 64, rows: 40)
            if let inside { cells = cells.filter { inside.contains($0) } }
            if cells.count >= 3 { changes.append((b.t, cells)) }
        }
        let window = 1.6
        var best: (score: Int, from: Double)?
        for c in changes {
            let score = changes.filter { $0.t >= c.t && $0.t < c.t + window }.reduce(0) { $0 + $1.cells.count }
            if score > (best?.score ?? 0) { best = (score, c.t) }
        }
        // A small change right where the user drew counts; elsewhere it takes more.
        guard let best, best.score >= (near == nil ? 8 : 4), let start = samples.first?.t, let end = samples.last?.t else { return nil }
        let within = changes.filter { $0.t >= best.from && $0.t < best.from + window }
        // One movement, start to end (a sidebar sliding, a menu opening): the biggest unbroken
        // run of change in the stretch. Frames spread over the whole stretch fell before and
        // after each movement and showed none of it.
        let step = zip(samples, samples.dropFirst()).map { $1.t - $0.t }.min() ?? 0.125
        var runs: [[(t: Double, cells: [Int])]] = []
        for c in within {
            if let last = runs.last?.last, c.t - last.t <= step * 1.5 { runs[runs.count - 1].append(c) } else { runs.append([c]) }
        }
        let run = runs.max { $0.reduce(0) { $0 + $1.cells.count } < $1.reduce(0) { $0 + $1.cells.count } }!
        // A change at t is between the sample before and t, and the frame log's frames don't
        // fall on the samples: start two steps back to be sure of a still frame.
        var from = run[0].t - 2 * step
        var to = run[run.count - 1].t + 0.04
        if to - from < 0.4 {
            let pad = (0.4 - (to - from)) / 2
            from -= pad
            to += pad
        }
        from = max(start, from)
        to = min(end, to)
        let count = 6
        let cells = Set(run.flatMap(\.cells))
        let xs = cells.map { $0 % 64 }
        let ys = cells.map { $0 / 64 }
        let area = CGRect(
            x: Double(xs.min()!) / 64 * display.width, y: Double(ys.min()!) / 40 * display.height,
            width: Double(xs.max()! - xs.min()! + 1) / 64 * display.width, height: Double(ys.max()! - ys.min()! + 1) / 40 * display.height)
        return Stretch(times: (0..<count).map { from + (to - from) * Double($0) / Double(count - 1) }, area: area)
    }

    /// The part of the screen to show: `area`, padded, between a quarter and half the screen
    /// each way (when it's more, the half around `focus`), so the frames stay readable.
    static func crop(_ area: CGRect, display size: CGSize, focus: CGPoint?) -> CGRect {
        let padded = area.insetBy(dx: -max(40, area.width * 0.15), dy: -max(40, area.height * 0.15))
        let w = min(max(padded.width, size.width * 0.25), size.width * 0.5)
        let h = min(max(padded.height, size.height * 0.25), size.height * 0.5)
        let cx = padded.width > w ? (focus?.x ?? padded.midX) : padded.midX
        let cy = padded.height > h ? (focus?.y ?? padded.midY) : padded.midY
        return CGRect(x: min(max(0, cx - w / 2), size.width - w), y: min(max(0, cy - h / 2), size.height - h), width: w, height: h)
    }

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
