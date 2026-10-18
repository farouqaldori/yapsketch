import CoreGraphics
import Foundation

// A Swift port of perfect-freehand by Steve Ruiz (https://github.com/steveruizok/perfect-freehand),
// the stroke engine behind tldraw's ink, under its MIT License:
//
// Copyright (c) 2021 Stephen Ruiz Ltd
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// Turns the points of a mouse stroke into the outline of a pressure-sensitive,
// tapered ink stroke (pressure simulated from speed), which is then filled.

enum PerfectFreehand {
    struct Options {
        var size: Double = 16
        var thinning: Double = 0.5
        var smoothing: Double = 0.5
        var streamline: Double = 0.5
        var simulatePressure = true
        var easing: (Double) -> Double = { $0 }
        var taperStart: Double = 0
        var taperEnd: Double = 0
        var capStart = true
        var capEnd = true
        /// The stroke is finished (use the real last point).
        var last = false
    }

    /// tldraw's freehand "draw" feel, for a pen of the given width.
    static func pen(width: Double, last: Bool) -> Options {
        var o = Options()
        o.size = 1 + width * 1.5
        o.thinning = 0.65
        o.smoothing = 0.65
        o.streamline = 0.65
        o.easing = { sin($0 * .pi / 2) }  // ease-out sine
        o.last = last
        return o
    }

    /// A highlighter: even width, no pressure.
    static func highlighter(width: Double, last: Bool) -> Options {
        var o = Options()
        o.size = width
        o.thinning = 0
        o.smoothing = 0.5
        o.streamline = 0.5
        o.simulatePressure = false
        o.last = last
        return o
    }

    /// The filled outline of a stroke through `points`, as a smooth closed path.
    static func path(_ points: [CGPoint], _ options: Options) -> CGPath {
        outlinePath(outline(strokePoints(points.map { V($0.x, $0.y) }, options), options))
    }

    // MARK: - Vector helpers

    private struct V {
        var x: Double, y: Double
        init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
        static func + (a: V, b: V) -> V { V(a.x + b.x, a.y + b.y) }
        static func - (a: V, b: V) -> V { V(a.x - b.x, a.y - b.y) }
        static func * (a: V, n: Double) -> V { V(a.x * n, a.y * n) }
        var neg: V { V(-x, -y) }
        var per: V { V(y, -x) }
        var len: Double { (x * x + y * y).squareRoot() }
        var uni: V {
            let l = len
            return l == 0 ? self : V(x / l, y / l)
        }
        func dpr(_ b: V) -> Double { x * b.x + y * b.y }
        func dist(_ b: V) -> Double { (self - b).len }
        func dist2(_ b: V) -> Double {
            let d = self - b
            return d.x * d.x + d.y * d.y
        }
        func lrp(_ b: V, _ t: Double) -> V { self + (b - self) * t }
        func prj(_ b: V, _ c: Double) -> V { self + b * c }
        func rot(around c: V, _ r: Double) -> V {
            let s = sin(r)
            let co = cos(r)
            let px = x - c.x
            let py = y - c.y
            return V(px * co - py * s + c.x, px * s + py * co + c.y)
        }
        var cg: CGPoint { CGPoint(x: x, y: y) }
    }

    private struct StrokePoint {
        var point: V
        var pressure: Double
        var vector: V
        var distance: Double
        var runningLength: Double
    }

    private static let ratePressureChange = 0.275
    private static let fixedPi = Double.pi + 0.0001
    private static let startCapSegments = 13.0, endCapSegments = 29.0, cornerCapSegments = 13.0
    private static let endNoiseThreshold = 3.0
    private static let minRadius = 0.01

    private static func simulatePressure(_ prev: Double, _ distance: Double, _ size: Double) -> Double {
        let sp = min(1, distance / size)
        let rp = min(1, 1 - sp)
        return min(1, prev + (rp - prev) * (sp * ratePressureChange))
    }

    private static func radius(_ size: Double, _ thinning: Double, _ pressure: Double, _ easing: (Double) -> Double) -> Double {
        size * easing(0.5 - thinning * (0.5 - pressure))
    }

    // MARK: - getStrokePoints

    private static func strokePoints(_ input: [V], _ o: Options) -> [StrokePoint] {
        guard !input.isEmpty else { return [] }
        let t = 0.15 + (1 - o.streamline) * 0.85
        var pts = input
        if pts.count == 2 {
            let last = pts[1]
            pts = [pts[0]]
            for i in 1..<5 { pts.append(pts[0].lrp(last, Double(i) / 4)) }
        }
        if pts.count == 1 { pts.append(pts[0] + V(1, 1)) }

        var out = [StrokePoint(point: pts[0], pressure: 0.25, vector: V(1, 1), distance: 0, runningLength: 0)]
        var reachedMinimum = false
        var running = 0.0
        var prev = out[0]
        let max = pts.count - 1
        for i in 1..<pts.count {
            let point = (o.last && i == max) ? pts[i] : prev.point.lrp(pts[i], t)
            if point.x == prev.point.x && point.y == prev.point.y { continue }
            let distance = point.dist(prev.point)
            running += distance
            if i < max && !reachedMinimum {
                if running < o.size { continue }
                reachedMinimum = true
            }
            prev = StrokePoint(point: point, pressure: 0.5, vector: (prev.point - point).uni, distance: distance, runningLength: running)
            out.append(prev)
        }
        out[0].vector = out.count > 1 ? out[1].vector : V(0, 0)
        return out
    }

    // MARK: - getStrokeOutlinePoints

    private static func outline(_ points: [StrokePoint], _ o: Options) -> [V] {
        guard !points.isEmpty, o.size > 0 else { return [] }
        let size = o.size
        let totalLength = points[points.count - 1].runningLength
        let taperStart = o.taperStart
        let taperEnd = o.taperEnd
        let taperStartEase: (Double) -> Double = { $0 * (2 - $0) }
        let taperEndEase: (Double) -> Double = {
            let t = $0 - 1
            return t * t * t + 1
        }
        let minDistance = pow(size * o.smoothing, 2)

        var left: [V] = []
        var right: [V] = []
        var prevPressure = points.prefix(10).reduce(points[0].pressure) { acc, p in
            (acc + (o.simulatePressure ? simulatePressure(acc, p.distance, size) : p.pressure)) / 2
        }
        var r = radius(size, o.thinning, points[points.count - 1].pressure, o.easing)
        var firstRadius: Double?
        var prevVector = points[0].vector
        var prevLeft = points[0].point
        var prevRight = prevLeft
        var tempLeft = prevLeft
        var tempRight = prevRight
        var prevSharp = false

        for i in points.indices {
            var pressure = points[i].pressure
            let p = points[i]
            let isLast = i == points.count - 1
            if !isLast && totalLength - p.runningLength < endNoiseThreshold { continue }

            if o.thinning != 0 {
                if o.simulatePressure { pressure = simulatePressure(prevPressure, p.distance, size) }
                r = radius(size, o.thinning, pressure, o.easing)
            } else {
                r = size / 2
            }
            if firstRadius == nil { firstRadius = r }

            let ts = p.runningLength < taperStart ? taperStartEase(p.runningLength / taperStart) : 1
            let te = totalLength - p.runningLength < taperEnd ? taperEndEase((totalLength - p.runningLength) / taperEnd) : 1
            r = Swift.max(minRadius, r * Swift.min(ts, te))

            let nextVector = (isLast ? p : points[i + 1]).vector
            let nextDpr = isLast ? 1.0 : p.vector.dpr(nextVector)
            let prevDpr = p.vector.dpr(prevVector)
            let isSharp = prevDpr < 0 && !prevSharp
            let nextSharp = nextDpr < 0

            if isSharp || nextSharp {
                let offset = prevVector.per * r
                var t = 0.0
                while t <= 1 {
                    tempLeft = (p.point - offset).rot(around: p.point, fixedPi * t)
                    left.append(tempLeft)
                    tempRight = (p.point + offset).rot(around: p.point, fixedPi * -t)
                    right.append(tempRight)
                    t += 1 / cornerCapSegments
                }
                prevLeft = tempLeft
                prevRight = tempRight
                if nextSharp { prevSharp = true }
                continue
            }
            prevSharp = false

            if isLast {
                let offset = p.vector.per * r
                left.append(p.point - offset)
                right.append(p.point + offset)
                continue
            }

            let offset = nextVector.lrp(p.vector, nextDpr).per * r
            tempLeft = p.point - offset
            if i <= 1 || prevLeft.dist2(tempLeft) > minDistance {
                left.append(tempLeft)
                prevLeft = tempLeft
            }
            tempRight = p.point + offset
            if i <= 1 || prevRight.dist2(tempRight) > minDistance {
                right.append(tempRight)
                prevRight = tempRight
            }
            prevPressure = pressure
            prevVector = p.vector
        }

        let first = points[0].point
        let last = points.count > 1 ? points[points.count - 1].point : points[0].point + V(1, 1)
        if points.count == 1 {
            if (taperStart == 0 && taperEnd == 0) || o.last {
                let start = first.prj((first - (first + V(1, 1))).per.uni, -(firstRadius ?? r))
                var dot: [V] = []
                var t = 1 / startCapSegments
                while t <= 1 {
                    dot.append(start.rot(around: first, fixedPi * 2 * t))
                    t += 1 / startCapSegments
                }
                return dot
            }
        }
        var startCap: [V] = []
        var endCap: [V] = []
        if points.count > 1, let r0 = right.first {
            if taperStart == 0 {
                if o.capStart {
                    var t = 1 / startCapSegments
                    while t <= 1 {
                        startCap.append(r0.rot(around: first, fixedPi * t))
                        t += 1 / startCapSegments
                    }
                } else if let l0 = left.first {
                    let c = (l0 - r0)
                    startCap += [first - c * 0.5, first - c * 0.51, first + c * 0.51, first + c * 0.5]
                }
            }
            let direction = points[points.count - 1].vector.neg.per
            if taperEnd > 0 {
                endCap.append(last)
            } else if o.capEnd {
                let start = last.prj(direction, r)
                var t = 1 / endCapSegments
                while t < 1 {
                    endCap.append(start.rot(around: last, fixedPi * 3 * t))
                    t += 1 / endCapSegments
                }
            } else {
                endCap += [last + direction * r, last + direction * (r * 0.99), last - direction * (r * 0.99), last - direction * r]
            }
        }
        return left + endCap + right.reversed() + startCap
    }

    // MARK: - Outline to path (quadratic curves through midpoints, as tldraw renders it)

    private static func outlinePath(_ pts: [V]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count > 2 else { return path }
        let n = pts.count
        func mid(_ i: Int) -> CGPoint {
            let a = pts[i % n]
            let b = pts[(i + 1) % n]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        path.move(to: mid(0))
        for i in 1...n { path.addQuadCurve(to: mid(i), control: pts[i % n].cg) }
        path.closeSubpath()
        return path
    }
}
