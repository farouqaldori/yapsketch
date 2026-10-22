import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PostProcessor {
    /// One picture per point, at the display's point size so event coordinates map 1:1 onto
    /// pixels. A point with marks shows the screen most of them are on, with faded ink put back.
    /// One without marks shows Jev's pick of moment.
    func pictures(
        asset: AVURLAsset, points: [SegmentAnalysis], events: [SessionEvent], duration: Double,
        words: [TranscriptSegment], frames: FrameLog?, previous: [SegmentAnalysis]
    ) async -> [Int: Screenshot] {
        let dir = session.dir.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let display = session.display.size
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = display
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        func frame(_ t: Double) async -> CGImage? {
            let shot = try? await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600))
            return shot?.image
        }
        func gray(_ t: Double) -> ScreenDiff.Gray? { frames?.at(t) }
        func write(_ image: CGImage, _ path: String) -> Bool {
            guard let dest = CGImageDestinationCreateWithURL(session.dir.appendingPathComponent(path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
        func area(_ e: SessionEvent) -> CGRect? { e.bbox.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
        /// When a mark is best seen: just after it was drawn; halfway through a pointer circle.
        func shown(_ m: SessionEvent) -> Double { m.kind == .gesture ? ((m.t0 ?? m.t) + m.t) / 2 : m.t + 0.25 }
        /// Cleared, or faded: an erase names the stroke.
        func gone(_ m: SessionEvent, _ e: SessionEvent) -> Bool {
            e.t > m.t && (e.kind == .clear || (e.kind == .erase && e.id == m.id))
        }
        func visible(_ m: SessionEvent, at t: Double) -> Bool {
            guard m.kind != .gesture, m.t <= t + 0.05 else { return false }
            return !events.contains { e in e.t <= t && gone(m, e) }
        }
        func faded(_ m: SessionEvent) -> Double? { events.first { gone(m, $0) }?.t }
        let drawn = events.filter { $0.kind == .annotation || $0.kind == .textNote }
        let split = frames.map { ScreenSplit(session: session, events: events, frames: $0) }
        func sameScreen(_ a: Double, _ b: Double, marks: [SessionEvent]) -> Bool { split?.sameScreen(a, b, marks: marks) ?? false }
        /// `image` (the screen at `t`) with `ink` put back where it had faded.
        func restoring(_ ink: [SessionEvent], at t: Double, onto image: CGImage) async -> CGImage {
            var image = image
            for m in ink where !visible(m, at: t) {
                // Late in its life the mark is whole and the pointer has usually moved on.
                let late = max(m.t + 0.2, min(m.t + 1.0, (faded(m) ?? .infinity) - 0.15))
                guard let b = area(m), let before = await frame((m.t0 ?? m.t) - 0.15), let after = await frame(late),
                    let back = Self.restoreInk(
                        b, before: before, after: after, onto: image, display: display,
                        pointer: stride(from: late - 0.1, through: late + 0.1, by: 0.05).compactMap { session.pointer(at: $0) })
                else { continue }
                image = back
            }
            return image
        }
        /// A picture before its number is stamped on.
        struct Still {
            let t: Double
            var marks: [SessionEvent] = []
            let image: CGImage
        }

        func picture(_ group: [SessionEvent], end: Double, isLast: Bool) async -> Still? {
            let drawings = group.filter { $0.kind != .gesture }
            var times = drawings.map(shown)
            if let last = group.last, isLast, sameScreen(shown(last), end, marks: group) { times.append(end) }
            // The moment most of its drawings show (the latest if tied); pointing only: the last circle.
            let t = times.max { a, b in
                let (va, vb) = (drawings.filter { visible($0, at: a) }.count, drawings.filter { visible($0, at: b) }.count)
                return va != vb ? va < vb : a < b
            } ?? group.last.map(shown) ?? end
            guard let shot = await frame(t) else { return nil }
            var image = await restoring(drawings, at: t, onto: shot)
            let lit = group.filter { $0.kind == .gesture }.compactMap {
                PointerGestures.spotlightRegion(session.pointerSamples, from: $0.t0 ?? $0.t, to: $0.t, on: image, display: display)
            }
            if !lit.isEmpty, let shaded = PointerGestures.drawSpotlight(lit, on: image, display: display) { image = shaded }
            return Still(t: t, marks: group, image: image)
        }

        // Each point runs until a little after its last word (or the next point's first).
        let ends = points.indices.map { k in
            let next = k + 1 < points.count ? points[k + 1].start : duration
            return min(max(points[k].end, min(points[k].end + 0.3, next)), max(0, duration - 0.05))
        }
        var stills: [Int: Still] = [:]
        var unmarked: [(key: Int, t: Double, said: String, candidates: [MomentPicker.Candidate])] = []
        /// The last point with nothing drawn and nothing happening, for when no other point has a picture.
        var quiet: (k: Int, t: Double, start: Double)?
        var busy: [(k: Int, t: Double, start: Double, score: Int)] = []
        for (k, p) in points.enumerated() {
            let t = ends[k]
            let start = k > 0 ? ends[k - 1] : 0
            let mine = events.filter { e in
                [.annotation, .textNote, .gesture].contains(e.kind) && (p.marks ?? []).contains { abs($0 - e.t) < 0.001 }
            }
            guard !mine.isEmpty else {
                if let judged = p.needsScreenshot {
                    guard judged > 0.5 else { continue }
                } else {
                    // Without Jev: a picture only if something happened (a click, a key, a window, the
                    // screen changing); the busiest fill the report's budget.
                    let from = max(start, p.start - 0.3)
                    let did = events.filter { [.click, .shortcut, .keys, .appSwitch, .window].contains($0.kind) && $0.t > from && $0.t <= t }.count
                    let changed = (frames?.changes ?? []).filter { $0[0] >= from && $0[0] <= t && $0[1] >= 8 }.reduce(0) { $0 + Int($1[1]) }
                    if did == 0 && changed == 0 {
                        quiet = (k, t, start)
                    } else {
                        busy.append((k, t, start, did * 20 + changed))
                    }
                    continue
                }
                let candidates = await momentCandidates(asset: asset, point: p, from: start, to: t, n: k, events: events, frames: frames)
                unmarked.append((k, t, p.text, candidates))
                continue
            }
            // Marks in a row on the same screen go together; the picture is the screen with the
            // most drawings (else pointed at most; the latest if tied).
            var groups: [[SessionEvent]] = []
            for m in mine {
                if let last = groups.last?.last, sameScreen(shown(last), shown(m), marks: groups[groups.count - 1] + [m]) {
                    groups[groups.count - 1].append(m)
                } else {
                    groups.append([m])
                }
            }
            func weight(_ i: Int) -> (Int, Int, Int) { (groups[i].filter { $0.kind != .gesture }.count, groups[i].count, i) }
            let main = groups.indices.max { weight($0) < weight($1) } ?? 0
            let group = groups[main]
            // As late as the point goes, but before another mark is begun.
            let next = drawn.filter { d in (d.t0 ?? d.t) > group.last!.t && !group.contains { $0.t == d.t } }.map { $0.t0 ?? $0.t }.min() ?? .infinity
            let end = max(group.map(shown).max()!, min(t, next - 0.1))
            if let still = await picture(group, end: end, isLast: main == groups.count - 1) { stills[k] = still }
        }

        // Marked points always get a picture; what's left of the budget (6 up to 40 s, one more per
        // 20 s, 12 at most) goes to the busiest of the rest. A report always has one.
        let budget = min(12, max(6, 6 + Int((duration - 40) / 20)))
        var picked = busy.sorted { $0.score > $1.score }.prefix(max(0, budget - stills.count - unmarked.count)).sorted { $0.k < $1.k }
        if stills.isEmpty, unmarked.isEmpty, picked.isEmpty, let q = quiet { picked = [(q.k, q.t, q.start, 0)] }
        for q in picked {
            let candidates = await momentCandidates(asset: asset, point: points[q.k], from: q.start, to: q.t, n: q.k, events: events, frames: frames)
            unmarked.append((q.k, q.t, points[q.k].text, candidates))
        }

        // Points without marks: Jev picks the moment (answers saved as the time by point, and
        // kept on re-runs for a point said in the same words).
        let momentsFile = session.dir.appendingPathComponent("moments.json")
        func near(_ t: Double, _ candidates: [MomentPicker.Candidate]) -> MomentPicker.Candidate? {
            candidates.min { abs($0.t - t) < abs($1.t - t) }.flatMap { abs($0.t - t) < 0.3 ? $0 : nil }
        }
        var chosen: [Int: Double] = [:]
        if let data = try? Data(contentsOf: momentsFile), let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            var said: [String: Double] = [:]
            for (k, t) in saved {
                if let k = Int(k), k < previous.count { said[previous[k].text] = t }
            }
            for u in unmarked { if let t = said[u.said], near(t, u.candidates) != nil { chosen[u.key] = t } }
        }
        let ask = unmarked.filter { chosen[$0.key] == nil }
        if smartPictures, !ask.isEmpty {
            step("Choosing moments…")
            let picks = ask.map { MomentPicker.Point(key: $0.key, said: $0.said, candidates: $0.candidates) }
            if let r = await MomentPicker(session: session, words: words).pick(picks) {
                for u in ask { if let i = r[u.key], i < u.candidates.count { chosen[u.key] = u.candidates[i].t } }
            }
        }
        try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: chosen.map { (String($0.key), ($0.value * 100).rounded() / 100) }))
            .write(to: momentsFile)
        for u in unmarked {
            guard let c = chosen[u.key].flatMap({ near($0, u.candidates) }) ?? u.candidates.max(by: { $0.t < $1.t }),
                let src = CGImageSourceCreateWithURL(session.dir.appendingPathComponent(c.path) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { continue }
            stills[u.key] = Still(t: c.t, image: image)
        }

        // Numbered in reading order, so the number in the text matches the one on the picture.
        var n = 0
        var out: [Int: Screenshot] = [:]
        for k in points.indices {
            guard let still = stills[k] else { continue }
            n += 1
            let path = "shots/\(n).jpg"
            let spots = still.marks.isEmpty ? [Badges.corner] : Badges.spots(still.marks.compactMap(area), display: display)
            guard let image = Badges.stamp(n, at: spots, on: still.image, display: display), write(image, path) else {
                n -= 1
                continue
            }
            out[k] = Screenshot(n: n, t: ends[k], picture: Picture(path: path, t: still.t, marks: still.marks))
        }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(".") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        return out
    }

    /// Frames a point's moment could be: its end, the moments the screen changed most, what each
    /// click led to, and frames spread across it (ten at most), saved as `.cand-` files.
    private func momentCandidates(
        asset: AVURLAsset, point p: SegmentAnalysis, from: Double, to t: Double, n: Int, events: [SessionEvent], frames: FrameLog?
    ) async -> [MomentPicker.Candidate] {
        let display = session.display.size
        // Moments the screen changed most, at 8 fps: something that shows for under a second
        // falls between frames spread seconds apart. Noted while recording when possible.
        var changes: [(t: Double, size: Int)] = []
        func note(_ at: Double, _ size: Int) {
            if let last = changes.last, at - last.t < 0.5 {
                if size > last.size { changes[changes.count - 1] = (min(at + 0.125, t), size) }
            } else {
                changes.append((min(at + 0.125, t), size))
            }
        }
        let begin = max(from, p.start - 0.3)
        for c in frames?.changes ?? [] where c[0] >= begin && c[0] <= t { note(c[0], Int(c[1])) }
        var times: [Double] = [t]
        let extra =
            changes.sorted { $0.size > $1.size }.prefix(4).map(\.t)
            + events.filter { ($0.kind == .click || $0.kind == .shortcut) && $0.t > from && $0.t < t }.map { min($0.t + 1.0, t) }
            + stride(from: begin + 2, to: t - 1, by: 4).map { $0 }
        for e in extra where !times.contains(where: { abs($0 - e) < 0.5 }) && times.count < 10 { times.append(e) }
        times.sort()

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = display
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        var out: [MomentPicker.Candidate] = []
        var left = Array(times.enumerated())
        for await result in gen.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            guard let image = try? result.image, let k = left.firstIndex(where: { abs($0.element - result.requestedTime.seconds) < 0.001 })
            else { continue }
            let (i, at) = left.remove(at: k)
            let path = "shots/.cand-\(n)-\(i).jpg"
            guard let dest = CGImageDestinationCreateWithURL(session.dir.appendingPathComponent(path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(dest) { out.append(MomentPicker.Candidate(t: at, path: path)) }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// A mark copied back from a frame where it showed: within its area (and room for its
    /// badge), the pixels that weren't there just before it began are the ink. Around the
    /// pointer is left out.
    static func restoreInk(
        _ area: CGRect, before: CGImage, after: CGImage, onto image: CGImage, display: CGSize, pointer: [CGPoint]
    ) -> CGImage? {
        let w = image.width
        let h = image.height
        guard before.width == w, after.width == w, before.height == h, after.height == h else { return nil }
        func pixels(_ img: CGImage) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            guard
                let ctx = CGContext(
                    data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard let a = pixels(before), let b = pixels(after), var out = pixels(image) else { return nil }
        let s = Double(w) / display.width
        // Rows run top-down in the buffer, like screen points.
        let r = area.insetBy(dx: -24, dy: -24)
        let x0 = max(0, Int(r.minX * s))
        let x1 = min(w, Int(r.maxX * s))
        let y0 = max(0, Int(r.minY * s))
        let y1 = min(h, Int(r.maxY * s))
        guard x0 < x1, y0 < y1 else { return nil }
        let cursor = pointer.map { CGRect(x: ($0.x - 12) * s, y: ($0.y - 12) * s, width: 46 * s, height: 54 * s) }
        for y in y0..<y1 {
            for x in x0..<x1 where !cursor.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                let i = (y * w + x) * 4
                let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
                if d > 48 { for c in 0..<4 { out[i + c] = b[i + c] } }
            }
        }
        guard
            let ctx = CGContext(
                data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        return ctx.makeImage()
    }
}
