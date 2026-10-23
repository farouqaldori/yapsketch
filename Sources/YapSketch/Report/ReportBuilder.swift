import Foundation

/// The paste (PROMPT.md), the report `yapsketch show` prints (REPORT.md) and what History reads
/// (report.json): the timeline of what was said and done, with the pictures.
struct ReportBuilder {
    let session: Session
    let duration: Double
    let events: [SessionEvent]
    let timeline: Timeline
    let pictures: [ReportPicture]
    let transcriptSource: String

    /// At most this many picture paths in the paste (each one is attached as an image); the
    /// timeline names every picture either way.
    static let pastedPictures = 10

    private var id: String { CLI.id(session.dir) }

    /// Where the recording started: `Google Chrome — Pull requests (github.com/acme/app/pulls)`.
    private var place: String {
        events.first(where: Timeline.isPlace).map(Timeline.place) ?? ""
    }

    private var header: String {
        let length = Fmt.clock(duration, decimals: false)
        return "Screen recording\(place.isEmpty ? "" : " in \(place)"), \(length). What I said and did, with my screen wherever I drew or pointed:"
    }

    private var lines: [String] { timeline.lines.isEmpty ? ["(Nothing was said or done.)"] : timeline.text() }

    private var lookCloser: String {
        "To see my screen at any moment: `yapsketch frames \(id) 01:23.4`, or a stretch: `yapsketch frames \(id) 01:20-01:30`."
    }

    /// The paste. Picture paths are on lines of their own: agents that turn pasted paths into
    /// attached images (Claude Code) take them all.
    func brief() -> String {
        var md = [header, ""] + lines
        if !pictures.isEmpty {
            md += ["", "Pictures, numbered like the badge on each:"]
            md += pictures.prefix(Self.pastedPictures).map { "\(session.dir.path)/\($0.path)" }
            if pictures.count > Self.pastedPictures {
                md.append("(\(pictures.count - Self.pastedPictures) more in \(session.dir.path)/shots/)")
            }
        }
        md += ["", lookCloser]
        return md.joined(separator: "\n") + "\n"
    }

    /// The report: the same timeline with each picture after the line it's for.
    func markdown() -> String {
        let date = DateFormatter.localizedString(from: session.startedAt, dateStyle: .medium, timeStyle: .short)
        var md = ["# Screen recording · \(date) · \(Fmt.clock(duration, decimals: false))", "", header]
        md.append("")
        if timeline.lines.isEmpty { md.append("(Nothing was said or done.)") }
        for (line, text) in zip(timeline.lines, timeline.text()) {
            md.append(text)
            for p in pictures where line.pictures.contains(p.n) {
                md += ["", "![\(p.n)](\(p.path))", ""]
            }
        }
        md += [
            "", "---",
            "_\(lookCloser) Words: \(transcriptSource), with their timings in `transcript.json`. Everything done: `events.jsonl`. Video: `recording.mp4`._",
            "",
        ]
        return md.joined(separator: "\n")
    }

    /// For History: the words with each picture's number where it was made, and the pictures.
    func summary() -> Data? {
        let json: [String: Any] = [
            "version": 1,
            "place": place,
            "length": Fmt.clock(duration, decimals: false),
            "words": transcriptSource,
            "narration": timeline.narration.map { piece -> [String: Any] in
                var d: [String: Any] = ["text": piece.text]
                if let m = piece.marker { d["marker"] = m }
                return d
            },
            "pictures": pictures.map { ["n": $0.n, "path": $0.path, "t": ($0.t * 100).rounded() / 100] },
        ]
        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
