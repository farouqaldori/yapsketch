import Foundation
import Security

/// One point the user made.
struct SegmentAnalysis: Codable {
    var index: Int
    let start: Double
    let end: Double
    let text: String
    var needsScreenshot: Double?
    /// The drawn marks and pointer circles it's about (when each ended, their `t`).
    var marks: [Double]?
    /// Its marker in the report ([n], and shots/<n>.jpg), when it has a picture.
    var n: Int?
}

/// Jev's judgment at one gap between words (kept for diagnosing segmentation).
struct SplitJudgment: Codable {
    let word: Int
    let newPoint: Double
    let choice: String?
}

/// Jev's judgment of which point a drawn mark or pointer circle is for.
struct MarkJudgment: Codable {
    /// The mark (when it ended).
    let t: Double
    /// Its point (in `segments`); nil when no point is about it.
    let point: Int?
    let probability: Double?
}

/// Jev's judgment of whether two marks in one point, one after the other, show different issues.
struct PairJudgment: Codable {
    /// The marks (when each ended).
    let a: Double
    let b: Double
    let apart: Double
}

struct SessionAnalysis: Codable {
    var version = 1
    /// Jev's points (or the transcript's sentences): where one issue ends and the next begins.
    var segments: [SegmentAnalysis] = []
    var splits: [SplitJudgment] = []
    /// The drawn marks Jev was shown while dividing (their `t`).
    var marked: [Double]?
    /// Which point each mark is for, as Jev judged (for these `segments`).
    var marks: [MarkJudgment]?
    var apart: [PairJudgment]?
    /// The points the report numbers: `segments`, each with its marks.
    var points: [SegmentAnalysis]?
    var questions = 0
    var inputTokens = 0
}

/// Groups transcript phrases into points, then asks Jev which point each mark is for and
/// which points need a picture.
struct PointFinder {
    let words: [TranscriptSegment]
    let screen: String
    var display = CGSize.zero
    /// What the user drew and circled with the pointer.
    var marks: [SessionEvent] = []
    /// The last run's analysis: answers to questions asked in the same words are kept.
    var previous: SessionAnalysis?

    func run() async -> SessionAnalysis? {
        guard let key = Jev.apiKey(), words.count > 1 else { return nil }
        var result = SessionAnalysis()

        var units: [Range<Int>] = []
        var unitStart = 0
        for i in words.indices {
            let sentenceEnd = words[i].text.last.map { ".?!".contains($0) } ?? false
            let pause = i + 1 < words.count ? words[i + 1].start - words[i].end : 0
            if i + 1 == words.count || sentenceEnd || pause >= 0.5 {
                units.append(unitStart..<(i + 1))
                unitStart = i + 1
            }
        }
        func text(_ r: Range<Int>) -> String { words[r].map(\.text).joined(separator: " ") }
        func text(units from: Int, _ to: Int) -> String {
            (max(0, from)..<min(units.count, to)).map { text(units[$0]) }.joined(separator: " ")
        }
        // What the user drew while saying each phrase (begun during it, or the pause before it):
        // marks on different things or the same thing say a lot about where one issue ends.
        let drawn = marks.filter { $0.kind != .gesture }.sorted { begun($0) < begun($1) }
        var drawnIn: [Int: [SessionEvent]] = [:]
        for m in drawn {
            let u =
                units.indices.first { u in
                    let end = words[units[u].upperBound - 1].end
                    let next = u + 1 < units.count ? words[units[u + 1].lowerBound].start : .infinity
                    return begun(m) <= max(end, min(end + 0.3, next))
                } ?? units.count - 1
            drawnIn[u, default: []].append(m)
        }
        func drawnWhile(_ u: Int) -> String? {
            drawnIn[u].map { $0.map(sketch).joined(separator: "; ") }
        }
        let sameMarks = Set(drawn.map { Int($0.t * 1000) }) == Set((previous?.marked ?? []).map { Int($0 * 1000) })
        if let p = previous, !p.splits.isEmpty, p.segments.map(\.text).joined(separator: " ") == text(0..<words.count), sameMarks {
            result.segments = p.segments.map { s in
                var s = s
                s.needsScreenshot = nil
                return s
            }
            result.splits = p.splits
            result.marked = p.marked
            result.marks = p.marks
            result.apart = p.apart
        } else {
            // Jev judges every pair of nearby phrases. The division is the one that agrees best
            // with all judgments at once, so one odd judgment can't split or merge a point.
            var cuts = [0]
            if units.count > 1 {
                let reach = 4
                var questions: [String: Any] = [:]
                for i in units.indices {
                    for j in (i + 1)..<min(units.count, i + 1 + reach) {
                        var instructions: [String: Any] = [
                            "a": text(units[i]),
                            "between": j > i + 1 ? text(units: i + 1, j) : "(nothing)",
                            "b": text(units[j]),
                            "question":
                                "`full_narration` is what a user said while narrating a screen recording for a developer, showing them the issues or changes they want, in one run-on stream. In it they said `a`, then `between`, then `b`. Are `a` and `b` about the same issue or request? Short pieces belong to the issue of the sentence they're part of.",
                        ]
                        if drawnWhile(i) != nil || drawnWhile(j) != nil {
                            instructions["drawn_while_saying_a"] = drawnWhile(i) ?? "(nothing)"
                            instructions["drawn_while_saying_b"] = drawnWhile(j) ?? "(nothing)"
                            instructions["question"] =
                                "\(instructions["question"]!) `drawn_while_saying_a` and `drawn_while_saying_b` are what they drew on the screen as they said each, to show what they meant: where it is and what it's on tell what each is about."
                        }
                        questions["same_\(i)_\(j)"] =
                            [
                                "type": "noul",
                                "instructions": instructions,
                                "criteria": [
                                    "true": "`a` and `b` are about the same issue or request (or set it up together).",
                                    "false": "`a` and `b` are about different issues or requests.",
                                ],
                            ] as [String: Any]
                    }
                }
                let state: [String: Any] = ["screen": screen, "full_narration": text(0..<words.count)]
                guard let r = await send(state: state, questions: questions, key: key) else { return nil }
                result.marked = drawn.map(\.t)
                result.questions += questions.count
                result.inputTokens += r.inputTokens
                var same: [Int: [Int: Double]] = [:]
                for i in units.indices {
                    for j in (i + 1)..<min(units.count, i + 1 + reach) {
                        same[i, default: [:]][j] = (r.answers["same_\(i)_\(j)"]?["noul"] as? NSNumber)?.doubleValue ?? 0.5
                    }
                }
                // Best division: putting two phrases in one point costs (1 - 2·same), so
                // same-issue pairs pull together and different-issue pairs push apart.
                func cost(_ a: Int, _ b: Int) -> Double {
                    var c = 0.0
                    for i in a..<b { for j in (i + 1)..<b where j - i <= reach { c += 1 - 2 * (same[i]?[j] ?? 0.5) } }
                    return c
                }
                var best = [0.0] + Array(repeating: Double.infinity, count: units.count)
                var from = Array(repeating: 0, count: units.count + 1)
                for b in 1...units.count {
                    for a in 0..<b where best[a] + cost(a, b) < best[b] {
                        best[b] = best[a] + cost(a, b)
                        from[b] = a
                    }
                }
                var bounds: [Int] = []
                var b = units.count
                while b > 0 {
                    bounds.append(from[b])
                    b = from[b]
                }
                for u in bounds.reversed() where u > 0 { cuts.append(units[u].lowerBound) }
                for u in 1..<units.count {
                    let p = same[u - 1]?[u] ?? 0.5
                    result.splits.append(
                        SplitJudgment(
                            word: units[u].lowerBound, newPoint: 1 - p, choice: cuts.contains(units[u].lowerBound) ? "new_issue" : "same_issue")
                    )
                }
            }
            cuts.append(words.count)
            for (k, (s, e)) in zip(cuts, cuts.dropFirst()).enumerated() where e > s {
                let ws = words[s..<e]
                result.segments.append(
                    SegmentAnalysis(
                        index: k, start: ws.first!.start, end: ws.last!.end,
                        text: ws.map(\.text).joined(separator: " ")))
            }
        }

        let known = result.marks ?? []
        let unjudged = marks.filter { m in !known.contains { abs($0.t - m.t) < 0.001 } }
        let segments = result.segments
        async let judged = judge(unjudged, points: segments, key: key)
        var points = Self.points(result.segments, saved: previous.map { [$0.segments, $0.points ?? []] } ?? [])
        var questions: [String: Any] = [:]
        for (k, p) in points.enumerated() where !p.text.isEmpty {
            let parts: [String: Any] = [
                "previous": k > 0 ? points[k - 1].text : "(start of recording)",
                "this_part": p.text,
                "next": k + 1 < points.count ? points[k + 1].text : "(end of recording)",
            ]
            if p.needsScreenshot == nil {
                questions["visual_\(k)"] =
                    [
                        "type": "noul",
                        "instructions": parts.merging([
                            "question":
                                "A user is narrating a screen recording for a developer. Does `this_part` itself (not `previous` or `next`) refer to something on the screen that the developer would need to see to understand it?"
                        ]) { a, _ in a },
                        "criteria": [
                            "true": "It points at or describes something visible on screen.",
                            "false": "Nothing on screen needs to be seen, e.g. a greeting, filler, a sign-off or a fragment like \"and\".",
                        ],
                    ] as [String: Any]
            }
        }
        if !questions.isEmpty, let r = await send(state: ["screen": screen, "narration": points.map(\.text)], questions: questions, key: key) {
            for k in points.indices {
                if let v = r.answers["visual_\(k)"]?["noul"] as? NSNumber { points[k].needsScreenshot = v.doubleValue }
            }
            result.questions += questions.count
            result.inputTokens += r.inputTokens
        }
        // Kept with the points they were asked about, before marks divide any.
        for k in points.indices {
            result.segments[k].needsScreenshot = points[k].needsScreenshot
        }
        if let j = await judged {
            result.marks = known + j.marks
            result.questions += j.questions
            result.inputTokens += j.inputTokens
        }
        points = Self.assign(marks, to: points, judged: result.marks ?? [])

        let compared = result.apart ?? []
        let pairs = Self.pairs(points, marks).filter { a, b in !compared.contains { abs($0.a - a.t) < 0.001 && abs($0.b - b.t) < 0.001 } }
        if let c = await compare(pairs, points: points, key: key) {
            result.apart = compared + c.apart
            result.questions += c.questions
            result.inputTokens += c.inputTokens
        }
        points = Self.divide(points, marks: marks, apart: result.apart ?? [], words: words, splits: result.splits)
        result.points = points
        Log.info(
            "jev: \(points.count) points (\(result.segments.count) issues) from \(words.count) words, \(marks.count) marks, \(result.questions) questions, \(result.inputTokens) input tokens"
        )
        return result
    }

    /// Which point each mark is for. Nil if Jev didn't answer.
    private func judge(_ marks: [SessionEvent], points: [SegmentAnalysis], key: String) async -> (
        marks: [MarkJudgment], questions: Int, inputTokens: Int
    )? {
        guard !marks.isEmpty, !points.isEmpty else { return ([], 0, 0) }
        var criteria: [String: Any] = [:]
        for (k, p) in points.enumerated() { criteria["p\(k)"] = "`points.p\(k)`: \"\(p.text)\"" }
        criteria["none"] = "None: no point is about what it marks (a stray stroke, a test, or nothing said refers to it)."
        var questions: [String: Any] = [:]
        for m in marks {
            questions["point_\(name(m))"] =
                [
                    "type": "choice",
                    "instructions": [
                        "mark": "`marks.\(name(m))`",
                        "question":
                            "A user narrated a screen recording for a developer, showing what they want changed or fixed. As they talked they drew on the screen or circled things with the mouse pointer to show what they meant (`marks`). `timeline` is what they said, with [m…] where they began each mark, and `points` are the points they made, in order. Which point is `mark` for: the point whose words are about what it marks? A mark is usually begun just before or while the words about it are said, sometimes just after. Several marks can be for one point (a circle and an arrow at the same thing, one shape drawn in two strokes).",
                    ] as [String: Any],
                    "criteria": criteria,
                ] as [String: Any]
        }
        guard let r = await send(state: state(points), questions: questions, key: key) else { return nil }
        let out = marks.compactMap { m -> MarkJudgment? in
            guard let a = r.answers["point_\(name(m))"], let choice = a["choice"] as? String else { return nil }
            let p = ((a["probabilities"] as? [String: Any])?[choice] as? NSNumber)?.doubleValue
            let k = choice.hasPrefix("p") ? Int(choice.dropFirst()) : nil
            Log.info("jev: \(name(m)) at \(Fmt.clock(m.t)) is for \(k.map { "point \($0)" } ?? "no point")\(p.map { String(format: " (%.2f)", $0) } ?? "")")
            return MarkJudgment(t: m.t, point: k.flatMap { $0 < points.count ? $0 : nil }, probability: p)
        }
        return (out, questions.count, r.inputTokens)
    }

    /// Whether each pair of marks shows different issues. Nil if Jev didn't answer.
    private func compare(_ pairs: [(SessionEvent, SessionEvent)], points: [SegmentAnalysis], key: String) async -> (
        apart: [PairJudgment], questions: Int, inputTokens: Int
    )? {
        guard !pairs.isEmpty else { return ([], 0, 0) }
        var questions: [String: Any] = [:]
        // How far apart they are, which is hard to read from two boxes' numbers.
        func between(_ a: SessionEvent, _ b: SessionEvent) -> String {
            guard let p = a.bbox, let q = b.bbox, p.count == 4, q.count == 4 else { return "(unknown)" }
            let dx = max(0, max(p[0] - (q[0] + q[2]), q[0] - (p[0] + p[2])))
            let dy = max(0, max(p[1] - (q[1] + q[3]), q[1] - (p[1] + p[3])))
            let d = Int(hypot(dx, dy))
            return d == 0 ? "They overlap." : "About \(d) px apart, on a \(Int(display.width))×\(Int(display.height)) screen."
        }
        for (a, b) in pairs {
            questions["apart_\(name(a))_\(name(b))"] =
                [
                    "type": "noul",
                    "instructions": [
                        "first": "`marks.\(name(a))`",
                        "then": "`marks.\(name(b))`",
                        "on_screen": between(a, b),
                        "question":
                            "A user narrated a screen recording for a developer, showing what they want changed or fixed, and drew on the screen or circled things with the mouse pointer to show what they meant (`marks`). `timeline` is what they said, with [m…] where they began each mark. They made `first` and then `then` for the same point. Do the two show different issues or requests?",
                    ] as [String: Any],
                    "criteria": [
                        "true": "Different issues or requests: two separate things to fix or change, each talked about on its own.",
                        "false": "The same issue or request: marks on the same thing (a circle and an arrow, one shape in two strokes), several places that need the same change, or one change involving both (move this there).",
                    ],
                ] as [String: Any]
        }
        guard let r = await send(state: state(points), questions: questions, key: key) else { return nil }
        let out = pairs.compactMap { a, b -> PairJudgment? in
            guard let v = r.answers["apart_\(name(a))_\(name(b))"]?["noul"] as? NSNumber else { return nil }
            Log.info(String(format: "jev: %@ and %@ show different issues: %.2f", name(a), name(b), v.doubleValue))
            return PairJudgment(a: a.t, b: b.t, apart: v.doubleValue)
        }
        return (out, questions.count, r.inputTokens)
    }

    /// A mark's name for Jev: m0, m1, … in the order they were begun.
    private func name(_ m: SessionEvent) -> String {
        "m\(marks.sorted { begun($0) < begun($1) }.firstIndex { $0.t == m.t && $0.kind == m.kind } ?? 0)"
    }

    private func state(_ points: [SegmentAnalysis]) -> [String: Any] {
        let all = marks.sorted { begun($0) < begun($1) }
        var timeline: [String] = []
        var left = all
        for w in words {
            while let m = left.first, begun(m) <= (w.start + w.end) / 2 {
                timeline.append("[\(name(m))]")
                left.removeFirst()
            }
            timeline.append(w.text)
        }
        timeline += left.map { "[\(name($0))]" }
        var said: [String: Any] = [:]
        for (k, p) in points.enumerated() { said["p\(k)"] = ["said": p.text, "when": "\(Fmt.clock(p.start))–\(Fmt.clock(p.end))"] }
        return [
            "screen": screen, "timeline": timeline.joined(separator: " "), "points": said,
            "marks": Dictionary(uniqueKeysWithValues: all.map { (name($0), describe($0)) }),
        ]
    }

    /// A mark in a few words: "drew a red box at x 10–80, y 5–40 on a 1512×982 screen, on button "Save"".
    private func sketch(_ m: SessionEvent) -> String {
        let d = describe(m)
        return [d["what"], d["where"].map { "at \($0)" }, d["on"].map { "on \($0)" }].compactMap { $0 as? String }.joined(separator: " ")
    }

    private func describe(_ m: SessionEvent) -> [String: Any] {
        let color = m.color.map { "\($0) " } ?? ""
        var d: [String: Any] = ["when": "\(Fmt.clock(begun(m)))–\(Fmt.clock(m.t))"]
        switch (m.kind, m.tool) {
        case (.gesture, _): d["what"] = "circled the mouse pointer around something"
        case (.textNote, _): d["what"] = "typed a \(color)note on the screen: \"\(m.text ?? "")\""
        case (_, "arrow"): d["what"] = "drew a \(color)arrow"
        case (_, "rect"): d["what"] = "drew a \(color)box"
        case (_, "highlight"): d["what"] = "drew a \(color)highlighter stroke"
        default: d["what"] = "drew a \(color)freehand line (a circle, underline, cross or scribble)"
        }
        if let b = m.bbox, b.count == 4 {
            d["where"] =
                "x \(Int(b[0]))–\(Int(b[0] + b[2])), y \(Int(b[1]))–\(Int(b[1] + b[3])) on a \(Int(display.width))×\(Int(display.height)) screen (0, 0 is the top left)"
        }
        if m.tool == "arrow", let x = m.x, let y = m.y { d["points_at"] = "x \(Int(x)), y \(Int(y))" }
        if let e = m.element { d["on"] = e }
        return d
    }

    // MARK: Points

    /// The points the report numbers, with a previous run's answers where a point and its
    /// neighbours read the same.
    static func points(_ segments: [SegmentAnalysis], saved: [[SegmentAnalysis]]) -> [SegmentAnalysis] {
        func reads(_ ps: [SegmentAnalysis], _ k: Int) -> [String] {
            [k > 0 ? ps[k - 1].text : "", ps[k].text, k + 1 < ps.count ? ps[k + 1].text : ""]
        }
        var answers: [[String]: SegmentAnalysis] = [:]
        for list in saved.reversed() {
            for k in list.indices where list[k].needsScreenshot != nil { answers[reads(list, k)] = list[k] }
        }
        return segments.indices.map { k in
            var p = SegmentAnalysis(index: k, start: segments[k].start, end: segments[k].end, text: segments[k].text)
            let old = answers[reads(segments, k)]
            p.needsScreenshot = old?.needsScreenshot ?? segments[k].needsScreenshot
            return p
        }
    }

    /// Each point's marks: the ones Jev judged are for it (a mark it judged no point is about
    /// is left out), else the ones begun during it or the pause before it. Without words, each
    /// drawn mark is a point of its own.
    static func assign(_ marks: [SessionEvent], to points: [SegmentAnalysis], judged: [MarkJudgment]) -> [SegmentAnalysis] {
        let marks = marks.sorted { begun($0) < begun($1) }
        guard !points.isEmpty else {
            return marks.filter { $0.kind != .gesture }.enumerated().map { k, m in
                var p = SegmentAnalysis(index: k, start: begun(m), end: m.t, text: "")
                p.marks = [m.t]
                return p
            }
        }
        var out = points
        for k in out.indices { out[k].marks = nil }
        for m in marks {
            let k: Int?
            if let j = judged.first(where: { abs($0.t - m.t) < 0.001 }) {
                k = j.point.flatMap { $0 < points.count ? $0 : nil }
            } else {
                // Point k runs until a little after its last word (or the next point's first).
                k =
                    points.indices.first { k in
                        k + 1 == points.count || begun(m) <= max(points[k].end, min(points[k].end + 0.3, points[k + 1].start))
                    }
            }
            if let k { out[k].marks = (out[k].marks ?? []) + [m.t] }
        }
        return out
    }

    /// Each point's marks, two at a time: each and the next one begun.
    static func pairs(_ points: [SegmentAnalysis], _ marks: [SessionEvent]) -> [(SessionEvent, SessionEvent)] {
        points.flatMap { p in
            let mine = marks.filter { m in (p.marks ?? []).contains { abs($0 - m.t) < 0.001 } }.sorted { begun($0) < begun($1) }
            return Array(zip(mine, mine.dropFirst()))
        }
    }

    /// Points whose marks Jev judged show different issues, divided: a new part begins with each
    /// mark judged apart from the one before it, its words cut between the two marks where Jev most
    /// thought a new issue began (else at the longest pause).
    static func divide(
        _ points: [SegmentAnalysis], marks: [SessionEvent], apart: [PairJudgment], words: [TranscriptSegment], splits: [SplitJudgment]
    ) -> [SegmentAnalysis] {
        let newPoint = Dictionary(splits.map { ($0.word, $0.newPoint) }, uniquingKeysWith: { a, _ in a })
        var out: [SegmentAnalysis] = []
        func add(_ p: SegmentAnalysis, _ start: Double, _ end: Double, _ text: String, _ marks: [SessionEvent]) {
            var q = SegmentAnalysis(index: out.count, start: start, end: end, text: text)
            q.needsScreenshot = p.needsScreenshot
            q.marks = marks.isEmpty ? nil : marks.map(\.t)
            out.append(q)
        }
        for p in points {
            let mine = marks.filter { m in (p.marks ?? []).contains { abs($0 - m.t) < 0.001 } }.sorted { begun($0) < begun($1) }
            var parts: [[SessionEvent]] = []
            for m in mine {
                let differs = parts.last?.last.map { a in apart.first { abs($0.a - a.t) < 0.001 && abs($0.b - m.t) < 0.001 }.map { $0.apart > 0.5 } ?? false } ?? true
                if differs { parts.append([m]) } else { parts[parts.count - 1].append(m) }
            }
            let ws = words.indices.filter { (words[$0].start + words[$0].end) / 2 >= p.start - 0.01 && (words[$0].start + words[$0].end) / 2 <= p.end + 0.01 }
            guard parts.count > 1 else {
                var q = p
                q.index = out.count
                out.append(q)
                continue
            }
            // Without word timings the text stays with the first part; later parts are just their marks.
            guard let first = ws.first, let last = ws.last else {
                for (i, part) in parts.enumerated() {
                    add(p, i == 0 ? p.start : begun(part[0]), max(i == 0 ? p.end : 0, part.last!.t), i == 0 ? p.text : "", part)
                }
                continue
            }
            // Cuts at word gaps: cut i is the first word of part i + 1.
            var cuts: [Int] = []
            var lowest = first + 1
            for i in 0..<(parts.count - 1) {
                let left = parts.count - 2 - i
                let gaps = Array(lowest...max(lowest, last + 1 - left))
                func at(_ g: Int) -> Double { g > last ? words[last].end : (words[g - 1].end + words[g].start) / 2 }
                let from = parts[i].last!.t
                let to = begun(parts[i + 1][0])
                let between = gaps.filter { at($0) >= min(from, to) && at($0) <= max(from, to) }
                let cut =
                    between.max { a, b in
                        let pa = (newPoint[a] ?? -1, a <= last ? words[a].start - words[a - 1].end : 0)
                        let pb = (newPoint[b] ?? -1, b <= last ? words[b].start - words[b - 1].end : 0)
                        return pa < pb
                    } ?? gaps.min { abs(at($0) - (from + to) / 2) < abs(at($1) - (from + to) / 2) } ?? lowest
                cuts.append(cut)
                lowest = cut + 1
            }
            for (i, part) in parts.enumerated() {
                let a = i == 0 ? first : cuts[i - 1]
                let b = i < cuts.count ? cuts[i] : last + 1
                if a < b, b <= last + 1 {
                    add(p, words[a].start, words[b - 1].end, words[a..<b].map(\.text).joined(separator: " "), part)
                } else {
                    add(p, begun(part[0]), part.last!.t, "", part)
                }
            }
        }
        return out
    }

    // MARK: Persistence

    static func write(_ r: SessionAnalysis, to dir: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(r).write(to: dir.appendingPathComponent("analysis.json"))
    }

    /// A previous run's analysis, so re-running a report doesn't call the API again.
    static func load(from dir: URL) -> SessionAnalysis? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("analysis.json")),
            let r = try? JSONDecoder().decode(SessionAnalysis.self, from: data)
        else { return nil }
        return r
    }

    // MARK: HTTP

    private struct Response {
        let answers: [String: [String: Any]]
        let inputTokens: Int
    }

    private func send(state: Any, questions: [String: Any], key: String) async -> Response? {
        let body: [String: Any] = ["model": Jev.model, "state": state, "questions": questions]
        #if DEBUG
        if let dry = ProcessInfo.processInfo.environment["YAPSKETCH_JEV_DRY_RUN"] {
            try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dry))
            Log.info("jev: dry run, wrote \(dry)")
            return nil
        }
        #endif
        guard let obj = await Jev.ask(body, key: key), let answers = obj["answers"] as? [String: [String: Any]] else { return nil }
        let tokens = ((obj["usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue ?? 0
        return Response(answers: answers, inputTokens: tokens)
    }
}

/// When a mark was begun (`t` is when it ended).
private func begun(_ m: SessionEvent) -> Double { m.t0 ?? m.t }
