import CoreGraphics
import Foundation

/// Comparing frames of the screen: small grayscale copies, and which cells of a grid changed.
enum ScreenDiff {
    static let cols = 32, rows = 20

    struct Gray {
        let px: [UInt8], w: Int, h: Int

        init(px: [UInt8], w: Int, h: Int) {
            self.px = px
            self.w = w
            self.h = h
        }

        init?(_ img: CGImage) {
            w = img.width
            h = img.height
            var p = [UInt8](repeating: 0, count: w * h)
            guard
                let ctx = CGContext(
                    data: &p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            px = p
        }
    }

    /// Grid cells covering these areas (screen points), one cell of margin for a ✏️ badge.
    static func cells(_ rects: [CGRect], display size: CGSize) -> Set<Int> {
        var out = Set<Int>()
        for r in rects {
            let x0 = Int(r.minX / size.width * Double(cols)) - 1
            let x1 = Int(r.maxX / size.width * Double(cols)) + 1
            let y0 = Int(r.minY / size.height * Double(rows)) - 1
            let y1 = Int(r.maxY / size.height * Double(rows)) + 1
            for y in max(0, y0)...min(rows - 1, max(0, y1)) {
                for x in max(0, x0)...min(cols - 1, max(0, x1)) { out.insert(y * cols + x) }
            }
        }
        return out
    }

    /// Grid cells (row-major, top row first) whose content changed: enough pixels changed
    /// strongly (text or shapes appearing, moving or going away). A window dimming or
    /// brightening as it loses or gains focus shifts everything a little and doesn't count.
    static func changed(_ a: Gray, _ b: Gray, ignoring skip: Set<Int>, cols: Int = cols, rows: Int = rows) -> [Int] {
        guard a.w == b.w, a.h == b.h else { return [] }
        var out: [Int] = []
        for cy in 0..<rows {
            for cx in 0..<cols where !skip.contains(cy * cols + cx) {
                var strong = 0
                var n = 0
                for y in (cy * a.h / rows)..<((cy + 1) * a.h / rows) {
                    for x in (cx * a.w / cols)..<((cx + 1) * a.w / cols) {
                        if abs(Int(a.px[y * a.w + x]) - Int(b.px[y * a.w + x])) > 40 { strong += 1 }
                        n += 1
                    }
                }
                if n > 0 && strong * 100 > n * 4 { out.append(cy * cols + cx) }
            }
        }
        return out
    }
}
