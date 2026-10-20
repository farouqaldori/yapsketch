import CoreGraphics
import Foundation

/// Where one picture can't show everything: two marks in a point, one after the other, with the
/// screen around them changed in between, are on different screens and each needs its own picture.
/// Read off the frames recorded while the user drew, so it holds with or without Jev.
struct ScreenSplit {
    let session: Session
    let events: [SessionEvent]
    let frames: FrameLog

    private var display: CGSize { session.display.size }
    private var drawn: [SessionEvent] { events.filter { $0.kind == .annotation || $0.kind == .textNote } }

    private func area(_ e: SessionEvent) -> CGRect? { e.bbox.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }

    /// When a mark is best seen: just after it was drawn; halfway through a pointer circle.
    func shown(_ m: SessionEvent) -> Double { m.kind == .gesture ? ((m.t0 ?? m.t) + m.t) / 2 : m.t + 0.25 }

    /// Cleared, or faded: an erase names the stroke.
    private func faded(_ m: SessionEvent) -> Double? {
        events.first { e in e.t > m.t && (e.kind == .clear || (e.kind == .erase && e.id == m.id)) }?.t
    }

    /// The same screen around these marks at `a` and `b`, apart from the user's ink and the pointer:
    /// what they marked is still where it was. Elsewhere may change (live captions, a clock), and
    /// a cell or two nearby (a spinner, a hover highlight).
    func sameScreen(_ a: Double, _ b: Double, marks: [SessionEvent]) -> Bool {
        guard let ga = frames.at(a), let gb = frames.at(b) else { return false }
        let around = ScreenDiff.cells(marks.compactMap(area).map { $0.insetBy(dx: -120, dy: -120) }, display: display)
        let ink = drawn.filter { ($0.t0 ?? $0.t) <= max(a, b) && (faded($0) ?? .infinity) >= min(a, b) }.compactMap(area)
        let pointer = [session.pointer(at: a), session.pointer(at: b)].compactMap { $0 }.map {
            CGRect(x: $0.x - 20, y: $0.y - 20, width: 40, height: 40)
        }
        let elsewhere = Set(0..<(ScreenDiff.cols * ScreenDiff.rows)).subtracting(around)
        return ScreenDiff.changed(ga, gb, ignoring: ScreenDiff.cells(ink + pointer, display: display).union(elsewhere)).count <= 2
    }

    /// For each pair of marks in a point, one after the other, on different screens: apart.
    /// Pairs on the same screen aren't judged here (they stay together unless Jev says otherwise).
    func apart(_ points: [SegmentAnalysis], marks: [SessionEvent]) -> [PairJudgment] {
        PointFinder.pairs(points, marks).compactMap { a, b in
            sameScreen(shown(a), shown(b), marks: [a, b]) ? nil : PairJudgment(a: a.t, b: b.t, apart: 1)
        }
    }
}
