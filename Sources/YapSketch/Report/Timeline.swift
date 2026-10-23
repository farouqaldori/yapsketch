import Foundation

/// What was said and done, in order: one line per phrase and one per thing done, each at its time.
/// The paste and the report are this, so an agent reads the words and the actions as they happened
/// and works out the rest itself.
struct Timeline {
    struct Line {
        let t: Double
        let text: String
        /// Said, rather than done.
        let spoken: Bool
        /// The pictures this line shows (a drawing or pointer circle).
        var pictures: [Int] = []
    }

    let lines: [Line]

    init(words: [TranscriptSegment], segments: [TranscriptSegment], events: [SessionEvent], pictures: [ReportPicture]) {
        let said = Self.phrases(words: words, segments: segments).map { Line(t: $0.start, text: $0.text, spoken: true) }
        let done = Self.actions(events, pictures: pictures)
        // A thing done at the same moment as a phrase starts follows it.
        lines = (said + done).enumerated().sorted { a, b in
            if a.element.t != b.element.t { return a.element.t < b.element.t }
            if a.element.spoken != b.element.spoken { return a.element.spoken }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Lines as text: `00:03.1  in a regular local mode,` and `00:06.4  [pressed ⌃A]`.
    func text() -> [String] { lines.map { "\(Fmt.clock($0.t))  \($0.text)" } }

    /// The words alone, each picture's number where its mark was begun (for History).
    var narration: [(text: String, marker: Int?)] {
        var out: [(String, Int?)] = []
        var pending: [String] = []
        for line in lines {
            if line.spoken {
                pending.append(line.text)
            } else {
                for n in line.pictures {
                    out.append((pending.joined(separator: " "), n))
                    pending = []
                }
            }
        }
        if !pending.isEmpty { out.append((pending.joined(separator: " "), nil)) }
        return out
    }

    // MARK: Phrases

    /// Words that leave a phrase unfinished when it ends on one: it runs on into the next.
    private static let dangling: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "for", "with", "in", "on", "at", "from", "into", "by", "so", "because",
        "my", "your", "our", "their", "its",
    ]

    /// Phrases cut where a sentence ends or the speaker pauses for half a second, a phrase that
    /// stops on "the", "and" or a single word joined to the next. Without word timings (live
    /// captions), the transcript's own segments.
    static func phrases(words: [TranscriptSegment], segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard words.count > 1 else {
            return segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var cut: [Range<Int>] = []
        var start = 0
        for i in words.indices {
            let ends = words[i].text.last.map { ".?!".contains($0) } ?? false
            let pause = i + 1 < words.count ? words[i + 1].start - words[i].end : 0
            if i + 1 == words.count || ends || pause >= 0.5 {
                cut.append(start..<(i + 1))
                start = i + 1
            }
        }
        var joined: [Range<Int>] = []
        var open: Range<Int>?
        for r in cut {
            let run = open.map { $0.lowerBound..<r.upperBound } ?? r
            let last = words[r.upperBound - 1].text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let unfinished = r.count == 1 || dangling.contains(last)
            if unfinished, r.upperBound < words.count, !(words[r.upperBound - 1].text.last.map { ".?!".contains($0) } ?? false) {
                open = run
            } else {
                joined.append(run)
                open = nil
            }
        }
        if let open { joined.append(open) }
        return joined.map { r in
            TranscriptSegment(start: words[r.lowerBound].start, end: words[r.upperBound - 1].end, text: words[r].map(\.text).joined(separator: " "))
        }
    }

    // MARK: Things done

    private static func actions(_ events: [SessionEvent], pictures: [ReportPicture]) -> [Line] {
        func picture(of e: SessionEvent) -> ReportPicture? { pictures.first { $0.mark.t == e.t && $0.mark.kind == e.kind } }
        var out: [Line] = []
        let events = events.sorted { $0.t < $1.t }
        // Where it starts is in the header; a line each time that changes.
        var place = events.first(where: isPlace).map(Self.place)
        var i = 0
        while i < events.count {
            let e = events[i]
            switch e.kind {
            case .annotation, .textNote, .gesture:
                let p = picture(of: e)
                out.append(Line(t: e.t0 ?? e.t, text: "[\(mark(e))\(p.map { " → \($0.n).jpg" } ?? "")]", spoken: false, pictures: p.map { [$0.n] } ?? []))
            case .keys:
                // A run of typing is one line.
                var typed = e.text ?? ""
                var j = i + 1
                while j < events.count, events[j].kind == .keys, events[j].t - events[j - 1].t < 2 {
                    typed += events[j].text ?? ""
                    j += 1
                }
                i = j - 1
                let shown = Self.typed(typed)
                if !shown.isEmpty { out.append(Line(t: e.t, text: "[typed \(shown)]", spoken: false)) }
            case .shortcut:
                out.append(Line(t: e.t, text: "[pressed \(e.text ?? "a shortcut")]", spoken: false))
            case .appSwitch, .window:
                guard isPlace(e) else { break }
                let now = Self.place(e)
                if !now.isEmpty, now != place { out.append(Line(t: e.t, text: "[now in \(now)]", spoken: false)) }
                place = now
            case .console:
                out.append(Line(t: e.t, text: "[browser error: \(e.text ?? "")]", spoken: false))
            case .clear:
                out.append(Line(t: e.t, text: "[cleared the drawings]", spoken: false))
            // Where a click landed is only a guess, and a bare `[clicked]` is noise.
            case .sessionStart, .sessionEnd, .erase, .scroll, .click:
                break
            }
            i += 1
        }
        return out
    }

    /// "drew", "pointed", "wrote "too big"": what the picture shows, and nothing guessed.
    static func mark(_ e: SessionEvent) -> String {
        switch e.kind {
        case .gesture: return "pointed"
        case .textNote: return "wrote \"\(e.text ?? "")\""
        default: return "drew"
        }
    }

    /// Typing as it reads: runs of a repeated key counted (`⌫×12`), long text shortened.
    static func typed(_ s: String) -> String {
        var out = ""
        var run: (Character, Int)?
        func flush() {
            guard let (c, n) = run else { return }
            out += n > 2 && !c.isLetter && !c.isNumber ? "\(c)×\(n)" : String(repeating: c, count: n)
            run = nil
        }
        for c in s {
            if let (r, n) = run, r == c { run = (r, n + 1) } else {
                flush()
                run = (c, 1)
            }
        }
        flush()
        let text = out.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        return "\"" + (text.count > 160 ? String(text.prefix(160)) + "…" : text) + "\""
    }

    /// Apps that come to the front without the user going anywhere: a notification, the Dock.
    private static let systemUI: Set<String> = [
        "UserNotificationCenter", "NotificationCenter", "Notification Center", "Control Center", "ControlCenter", "Dock",
        "loginwindow", "SystemUIServer", "Spotlight", "screencaptureui", "WindowManager",
    ]

    /// An app or window the user went to (not a notification popping up).
    static func isPlace(_ e: SessionEvent) -> Bool {
        (e.kind == .appSwitch || e.kind == .window) && !systemUI.contains(e.app ?? "")
    }

    /// What a browser puts in a tab's title after the page's own.
    private static let tabStates = [" - Audio playing", " - Muted", " - Camera or microphone recording", " - Camera recording", " - Microphone recording"]

    /// The app, its window's title (without the browser's own name and profile after it, and a
    /// file's folders), and the page's address: `Google Chrome — Pull requests (github.com/acme/app/pulls)`.
    static func place(_ e: SessionEvent) -> String {
        guard let app = e.app else { return "" }
        var s = app
        var title = e.window ?? ""
        if let r = title.range(of: " - \(app)") ?? title.range(of: " — \(app)") { title = String(title[..<r.lowerBound]) }
        for state in tabStates where title.hasSuffix(state) { title.removeLast(state.count) }
        // `Adobe After Effects 2026 - /private/tmp/… /demo.aep`: the file's name.
        if let r = title.range(of: #"(^|\s)~?/\S"#, options: .regularExpression) {
            let name = title[r.lowerBound...].split(separator: "/").last.map(String.init) ?? ""
            title = String(title[..<r.lowerBound]) + (r.lowerBound == title.startIndex ? "" : " ") + name
        }
        if !title.isEmpty, title != app { s += " — \(title)" }
        if let raw = e.url, let u = URL(string: raw) {
            if u.isFileURL {
                if !title.contains(u.lastPathComponent) { s += " (\(u.lastPathComponent))" }
            } else {
                var address = (u.host ?? "") + u.path
                if let q = u.query { address += "?" + q }
                s += " (\(address))"
            }
        }
        return s
    }
}
