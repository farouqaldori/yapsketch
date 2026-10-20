import Foundation

/// A recording as History shows it, read from its REPORT.md.
struct RecordingSummary: Identifiable, Hashable {
    let id: String  // the folder name
    let folder: URL
    let date: Date
    /// Where it was recorded: the page or the app.
    let title: String
    let length: String
    /// The narration in pieces: text, then the marker it leads up to (nil for the last piece).
    let narration: [(text: String, marker: Int?)]
    let points: [Point]
    /// Why its report couldn't be made (the recording is kept, to try again).
    var failure: String? = nil

    static let failureFile = "report-failed.txt"

    struct Point: Hashable {
        let n: Int
        let picture: URL?
    }

    static func == (a: RecordingSummary, b: RecordingSummary) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var plainNarration: String {
        let words = narration.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? "(No speech)" : words
    }

    static func all() -> [RecordingSummary] { CLI.recordings().compactMap(load) + failed() }

    /// Recordings whose report couldn't be made: the words heard live, if any.
    static func failed() -> [RecordingSummary] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppDelegate.sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            guard !fm.fileExists(atPath: dir.appendingPathComponent("REPORT.md").path),
                let why = try? String(contentsOf: dir.appendingPathComponent(failureFile), encoding: .utf8)
            else { return nil }
            let live = (try? Data(contentsOf: dir.appendingPathComponent("live-transcript.json")))
                .flatMap { try? JSONDecoder().decode([TranscriptSegment].self, from: $0) } ?? []
            let words = live.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let date = Storage.date(of: dir) ?? ((try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
            return RecordingSummary(
                id: dir.lastPathComponent, folder: dir, date: date, title: "Screen recording", length: "",
                narration: words.isEmpty ? [] : [(words, nil)], points: [],
                failure: why.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func load(_ dir: URL) -> RecordingSummary? {
        guard let report = try? String(contentsOf: dir.appendingPathComponent("REPORT.md"), encoding: .utf8) else { return nil }
        let lines = report.components(separatedBy: "\n")
        // "# Screen recording · 17 Oct 2026 at 03:51 · 00:13"
        let length = lines.first?.components(separatedBy: " · ").last ?? ""
        let place = ((try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n").lazy
            .compactMap { try? JSONDecoder().decode(SessionEvent.self, from: Data($0.utf8)) }
            .first { $0.kind == .appSwitch || $0.kind == .window }
        var title = place?.app ?? "Screen recording"
        if let url = place?.url.flatMap(URL.init(string:)), let host = url.host {
            title = host + (url.path.count > 1 ? url.path : "")
        }
        let narrationLine = lines.first { $0.contains("[1]") && !$0.hasPrefix("**") } ?? ""
        var pieces: [(String, Int?)] = []
        var rest = Substring(narrationLine)
        while let r = rest.range(of: #"\[(\d+)\]"#, options: .regularExpression) {
            let n = Int(rest[r].dropFirst().dropLast())
            pieces.append((String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), n))
            rest = rest[r.upperBound...]
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append((tail, nil)) }
        // No markers (no point got a picture): the words from the transcript.
        if pieces.isEmpty, let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
            let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            let words = segments.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !words.isEmpty { pieces.append((words, nil)) }
        }

        // Each "**[n]** time" block and its picture, "![n](shots/n.jpg)".
        var points: [Point] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.hasPrefix("**["), let close = line.firstIndex(of: "]"),
                let n = Int(line[line.index(line.startIndex, offsetBy: 3)..<close])
            else {
                i += 1
                continue
            }
            var picture: URL?
            i += 1
            while i < lines.count, !lines[i].hasPrefix("**["), lines[i] != "---" {
                let l = lines[i]
                if l.hasPrefix("!["), let open = l.range(of: "]("), l.hasSuffix(")") {
                    picture = dir.appendingPathComponent(String(l[open.upperBound..<l.index(before: l.endIndex)]))
                }
                i += 1
            }
            points.append(Point(n: n, picture: picture))
        }

        let date = Storage.date(of: dir) ?? ((try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
        return RecordingSummary(
            id: dir.lastPathComponent, folder: dir, date: date, title: title, length: length,
            narration: pieces, points: points)
    }
}
