import AppKit
import Vision

/// Pointing with the mouse: circling or wiggling it over something ("this, here") instead of
/// drawing on it, often because what it points at is gone too quickly to draw on. Found from
/// how the pointer moved: back and forth, or round, within a small area.
enum PointerGestures {
    /// Gestures in the pointer samples ([t, x, y]), as events with the area pointed at.
    /// `busy`: times the pointer was doing something else (drawing). `clicks`: click times;
    /// moving back and forth between clicks is using the app, not pointing.
    static func find(_ samples: [[Double]], excluding busy: [ClosedRange<Double>], clicks: [Double]) -> [SessionEvent] {
        let pts = samples.filter { s in !busy.contains { $0.contains(s[0]) } }
        guard pts.count > 4 else { return [] }

        // Windows of 0.8 s that look like pointing, merged where they overlap.
        var spans: [(from: Double, to: Double)] = []
        var j = 0
        for i in pts.indices {
            j = max(j, i)
            while j + 1 < pts.count, pts[j + 1][0] <= pts[i][0] + 0.8 { j += 1 }
            let w = Array(pts[i...j])
            guard w.count >= 5, clicks.filter({ $0 >= w[0][0] && $0 <= w[w.count - 1][0] }).count < 2, isPointing(w) else { continue }
            if let last = spans.last, w[0][0] <= last.to + 0.15 {
                spans[spans.count - 1].to = max(last.to, w[w.count - 1][0])
            } else {
                spans.append((w[0][0], w[w.count - 1][0]))
            }
        }

        // Pointing at the same thing again after a short pause is one gesture.
        func center(_ s: (from: Double, to: Double)) -> CGPoint {
            let p = pts.filter { $0[0] >= s.from && $0[0] <= s.to }
            return CGPoint(x: p.map { $0[1] }.reduce(0, +) / Double(p.count), y: p.map { $0[2] }.reduce(0, +) / Double(p.count))
        }
        var merged: [(from: Double, to: Double)] = []
        for s in spans {
            if let last = merged.last, s.from - last.to <= 1.0 {
                let a = center(last)
                let b = center(s)
                if abs(a.x - b.x) <= 150, abs(a.y - b.y) <= 150 {
                    merged[merged.count - 1].to = s.to
                    continue
                }
            }
            merged.append(s)
        }

        var out: [SessionEvent] = []
        for s in merged where s.to - s.from >= 0.5 {
            let p = pts.filter { $0[0] >= s.from && $0[0] <= s.to }
            let xs = p.map { $0[1] }
            let ys = p.map { $0[2] }
            var e = SessionEvent(t: s.to, kind: .gesture)
            e.t0 = s.from
            e.bbox = [xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!]
            e.x = (xs.min()! + xs.max()!) / 2
            e.y = (ys.min()! + ys.max()!) / 2
            out.append(e)
        }
        return out
    }

    /// Back and forth or round within a small area, unhurried: several changes of direction
    /// and a path much longer than the area is wide (one circle is ~2.2× its bounding box's
    /// diagonal). Pointing is slow (under ~100 pt/s); swooping across the screen on the way
    /// somewhere is many times faster.
    private static func isPointing(_ w: [[Double]]) -> Bool {
        let xs = w.map { $0[1] }
        let ys = w.map { $0[2] }
        let bw = xs.max()! - xs.min()!
        let bh = ys.max()! - ys.min()!
        guard max(bw, bh) <= 450, max(bw, bh) >= 25 else { return false }
        var length = 0.0
        var reversals = 0
        var lastDX = 0.0
        var lastDY = 0.0
        var speeds: [Double] = []
        for (a, b) in zip(w, w.dropFirst()) {
            let dx = b[1] - a[1]
            let dy = b[2] - a[2]
            let step = (dx * dx + dy * dy).squareRoot()
            length += step
            if b[0] > a[0] { speeds.append(step / (b[0] - a[0])) }
            if abs(dx) >= 3 {
                if lastDX != 0, (dx > 0) != (lastDX > 0) { reversals += 1 }
                lastDX = dx
            }
            if abs(dy) >= 3 {
                if lastDY != 0, (dy > 0) != (lastDY > 0) { reversals += 1 }
                lastDY = dy
            }
        }
        let median = speeds.sorted()[speeds.count / 2]
        return median <= 350 && reversals >= 3 && length >= 2 * max(20, (bw * bw + bh * bh).squareRoot())
    }

    /// Where a gesture pointed, in screen points: the pointer's path, grown to whole lines of
    /// on-screen text it touched (so "This Mac" is lit, not half of it), with generous room
    /// around it, since a pointer only roughly circles what it means.
    static func spotlightRegion(_ samples: [[Double]], from t0: Double, to t1: Double, on image: CGImage, display: CGSize) -> CGRect? {
        let pts = samples.filter { $0[0] >= t0 && $0[0] <= t1 }.map { CGPoint(x: $0[1], y: $0[2]) }
        guard pts.count > 1 else { return nil }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let path = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        var region = path
        for line in textLines(near: path, on: image, display: display) {
            // A line counts when the pointer went over most of its height.
            let overlap = min(line.maxY, path.maxY) - max(line.minY, path.minY)
            guard line.intersects(path.insetBy(dx: -4, dy: -4)), overlap >= 0.4 * line.height else { continue }
            region = region.union(line)
        }
        // Never more than a part of the screen, even if a line is very long.
        region.size.width = min(region.width, max(path.width + 360, display.width * 0.45))
        let pad = max(36, 0.3 * max(region.width, region.height))
        region = region.insetBy(dx: -pad, dy: -pad * 0.8)
        let minW = 260.0
        let minH = 120.0
        if region.width < minW { region = region.insetBy(dx: -(minW - region.width) / 2, dy: 0) }
        if region.height < minH { region = region.insetBy(dx: 0, dy: -(minH - region.height) / 2) }
        return region.intersection(CGRect(origin: .zero, size: display))
    }

    /// The text lines (screen points) around `area`, read with Vision.
    private static func textLines(near area: CGRect, on image: CGImage, display: CGSize) -> [CGRect] {
        let s = Double(image.width) / display.width
        let roi = area.insetBy(dx: -260, dy: -80).intersection(CGRect(origin: .zero, size: display))
        guard !roi.isEmpty,
            let crop = image.cropping(to: CGRect(x: roi.minX * s, y: roi.minY * s, width: roi.width * s, height: roi.height * s).integral)
        else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: crop).perform([request])
        return (request.results ?? []).map { o in
            let b = o.boundingBox
            return CGRect(
                x: roi.minX + b.minX * roi.width, y: roi.minY + (1 - b.maxY) * roi.height,
                width: b.width * roi.width, height: b.height * roi.height)
        }
    }

    /// Dims everything but `regions` (screen points), with a soft edge: what the pointer meant,
    /// lit, and nothing drawn over it. Overlapping ones merge, so the shade stays even.
    static func drawSpotlight(_ regions: [CGRect], on image: CGImage, display: CGSize) -> CGImage? {
        guard
            let ctx = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = Double(image.width) / display.width
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: full)
        // Screen points (top-left origin) to image pixels (bottom-left origin).
        let holes = regions.map { CGRect(x: $0.minX * s, y: Double(image.height) - $0.maxY * s, width: $0.width * s, height: $0.height * s) }
        let steps = 14
        let feather = 22 * s
        let dim = 0.6
        for k in 0..<steps {
            // Each ring a little further out adds a little more shade: a soft edge.
            let grow = feather * Double(k) / Double(steps)
            let path = CGMutablePath()
            path.addRect(full)
            for r in merged(holes.map { $0.insetBy(dx: -grow, dy: -grow) }) {
                path.addRoundedRect(in: r, cornerWidth: min(18 * s, r.width / 2), cornerHeight: min(18 * s, r.height / 2))
            }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(1 - pow(1 - dim, 1 / Double(steps))).cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        return ctx.makeImage()
    }

    /// Rectangles with every overlapping pair replaced by their union (even-odd fills need them apart).
    private static func merged(_ rects: [CGRect]) -> [CGRect] {
        var out = rects
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i && out[i].intersects(out[j]) {
                    out[i] = out[i].union(out[j])
                    out.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return out
    }
}
