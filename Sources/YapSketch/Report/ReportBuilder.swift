import Foundation

/// Builds the recording report and clipboard prompt from the narration and selected pictures.
struct ReportBuilder {
    let session: Session
    let duration: Double
    let events: [SessionEvent]
    let points: [SegmentAnalysis]
    let shots: [Int: Screenshot]
    let transcriptSource: String
    /// "Jev" when the points come from Jev, nil when they're the transcript's sentences.
    let segmentedBy: String?

    /// My words with a marker after each point that has a picture.
    private func narration() -> String {
        points.enumerated().map { k, p in
            [p.text, shots[k].map { "[\($0.n)]" } ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func markdown() -> String {
        var md: [String] = []
        let date = DateFormatter.localizedString(from: session.startedAt, dateStyle: .medium, timeStyle: .short)
        md.append("# Screen recording · \(date) · \(Fmt.clock(duration, decimals: false))")
        md.append("")
        if let app = events.first(where: { $0.kind == .appSwitch || $0.kind == .window }) {
            md.append(context(app))
            md.append("")
        }

        if points.isEmpty {
            md.append("_No speech was captured._")
        } else {
            md.append(narration())
        }
        md.append("")

        let notes = notesByShot()
        let ordered = shots.sorted { $0.value.n < $1.value.n }
        if !ordered.isEmpty {
            md.append("---")
            md.append("")
            for (k, shot) in ordered {
                let pic = shot.picture
                md.append((["**[\(shot.n)]** \(Fmt.clock(pic.t))"] + (notes[k] ?? [])).joined(separator: " · "))
                md.append("")
                if let first = pic.frames.first, let last = pic.frames.last {
                    let marks = pic.marks.contains { $0.kind != .gesture } ? ", what I drew kept on each" : ""
                    md.append("Frames from \(Fmt.clock(first)) to \(Fmt.clock(last)), left to right, where the screen changed most\(marks):")
                    md.append("")
                } else if !pic.marks.isEmpty {
                    let lit = pic.marks.contains { $0.kind == .gesture } ? " (where the pointer circled is lit, the rest dimmed)" : ""
                    md.append("\(pic.shows) at \(Fmt.clock(pic.t)), numbered \(shot.n)\(lit):")
                    md.append("")
                }
                md.append("![\(shot.n)](\(pic.path))")
                md.append("")
            }
        }

        md.append("---")
        md.append(
            "_Each [n] marks where I was in my narration. Its picture is my screen at that moment, with what I drew or circled for it and its number n next to that (in the corner when there's none). For something moving, frames go left to right. To look closer at any [n] or moment: `yapsketch frames \(CLI.id(session.dir)) <n|mm:ss>`. Transcript: \(transcriptSource)\(segmentedBy.map { ", points by \($0)" } ?? ""). Full video: `recording.mp4`. Raw data: `events.jsonl`, `transcript.json`._"
        )
        md.append("")
        return md.joined(separator: "\n")
    }

    /// The instructions to paste into an agent (PROMPT.md, copied when a recording is done):
    /// my words with their markers, then the pictures (shots/<n>.jpg is marker n's), each path on
    /// a line of its own so agents that turn pasted paths into attached images (Claude Code) take
    /// them all, and the command for the rest. Text and pictures don't interleave.
    func brief() -> String {
        var md: [String] = []
        md.append(points.isEmpty ? "(No speech was captured.)" : narration())
        let pictures = shots.values.sorted { $0.n < $1.n }.map(\.picture)
        if !pictures.isEmpty {
            md.append("")
            md += pictures.map { "\(session.dir.path)/\($0.path)" }
        }
        md.append("")
        md.append("For the details, run `yapsketch show \(CLI.id(session.dir))`.")
        return md.joined(separator: "\n")
    }

    /// What I did during each point, attached to the next screenshot taken (a mark to its own
    /// point's): drawings and typing as they happened, and the page it started on and ended up on.
    /// A mark no point is about, or not in its point's picture, says so.
    private func notesByShot() -> [Int: [String]] {
        let shotPoints = shots.keys.sorted()
        guard let last = shotPoints.last else { return [:] }
        func owner(_ e: SessionEvent) -> Int? { points.indices.first { k in (points[k].marks ?? []).contains { abs($0 - e.t) < 0.001 } } }
        var grouped: [Int: [SessionEvent]] = [:]
        for e in events {
            let own = owner(e).flatMap { shots[$0] == nil ? nil : $0 }
            let k = own ?? shotPoints.first { shots[$0]!.t >= e.t } ?? last
            grouped[k, default: []].append(e)
        }
        var out: [Int: [String]] = [:]
        for (k, evs) in grouped {
            var notes = evs.filter { ![.click, .appSwitch, .window, .clear, .erase].contains($0.kind) }.compactMap { e -> String? in
                guard let said = note(e) else { return nil }
                guard [.annotation, .textNote, .gesture].contains(e.kind) else { return said }
                if owner(e) == nil { return said + " (no point is about it)" }
                return shots[k]!.picture.marks.contains { $0.t == e.t } ? said : said + " (not in the picture)"
            }
            var pages: [String] = []
            for e in evs where (e.kind == .appSwitch || e.kind == .window) && e.t >= 0.5 {
                // The header has the full address; here the path is enough to follow along.
                let page = shortPage(e)
                if !pages.contains(page) { pages.append(page) }
            }
            if !pages.isEmpty {
                notes.append("🪟 " + (pages.count > 2 ? [pages[0], "…", pages[pages.count - 1]] : pages).joined(separator: " → "))
            }
            out[k] = notes
        }
        return out
    }

    /// A page as a path (`/projects/…/logs?log=…`), or the window title without a URL.
    private func shortPage(_ e: SessionEvent) -> String {
        guard let raw = e.url, let u = URL(string: raw) else { return e.window ?? e.app ?? "" }
        if u.isFileURL { return u.lastPathComponent }
        var path = u.path
        if let q = u.query { path += "?" + q }
        return "`\(path)`"
    }

    private func note(_ e: SessionEvent) -> String? {
        switch e.kind {
        case .annotation:
            let shape = ["arrow": "arrow", "rect": "box", "highlight": "highlight"][e.tool ?? ""] ?? "mark"
            let on = e.element.map { " on \($0)" } ?? ""
            return "✏️ drew a \(e.color ?? "") \(shape)\(on)"
        case .textNote:
            return "✏️ wrote \"\(e.text ?? "")\""
        case .click:
            let on = e.element.map { " \($0)" } ?? ""
            return "🖱 clicked\(on)"
        case .keys:
            return "⌨️ typed `\(e.text ?? "")`"
        case .shortcut:
            return "⌨️ pressed `\(e.text ?? "")`"
        case .appSwitch, .window:
            return e.t < 0.5 ? nil : "🪟 \(context(e))"
        case .clear:
            return "✏️ cleared drawings"
        case .console:
            return "⚠️ \(e.text ?? "console error")"
        case .gesture:
            return "🖱 circled something with the pointer"
        case .sessionStart, .sessionEnd, .erase, .scroll:
            return nil
        }
    }

    private func context(_ e: SessionEvent) -> String {
        var s = e.app ?? ""
        if let w = e.window { s += " — \(w)" }
        if let u = e.url {
            let url = URL(string: u).flatMap { $0.isFileURL ? $0.path : nil } ?? u
            s += " (`\(url)`)"
        }
        return s
    }
}
