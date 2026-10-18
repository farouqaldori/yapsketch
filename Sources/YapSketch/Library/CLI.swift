import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `yapsketch <command>`: the recordings for coding agents (and people) on the command line.
/// The app's own executable answers these; `yapsketch` on the PATH is a small wrapper the
/// app installs that runs it.
enum CLI {
    static let commands: Set<String> = ["latest", "list", "show", "brief", "path", "frames", "reprocess", "help", "--help", "-h"]

    static let usage = """
        yapsketch: YapSketch screen recordings (what the user said while showing their screen,
        with a numbered picture for each [n] marker in the narration).

          yapsketch latest            the newest recording's report
          yapsketch show <recording>  a recording's report (its id from `list`, or a path)
          yapsketch brief [recording] the short instructions (what's copied when a recording ends)
          yapsketch list [-n N]       recent recordings: when, how long, how they start
          yapsketch path [recording]  a recording's folder (the newest by default)
          yapsketch frames <recording> <n|mm:ss> [--count N]
                                     frames around marker [n] or a moment, side by side in
                                     one picture (8 by default), to look closer, and prints its path
          yapsketch reprocess <recording> [--jev]
                                     build a report again (--jev: ask Jev what changed)

        Reports are Markdown. Image paths are absolute: open each image to see what the user
        showed. Marker n's picture has a coral badge n next to what they drew or circled for it,
        or in its corner, and the spot the pointer circled is lit.
        Add --json for JSON.
        """

    /// Runs `args` (without the executable) and exits.
    static func run(_ args: [String]) -> Never {
        let json = args.contains("--json")
        let rest = args.filter { $0 != "--json" }
        switch rest.first {
        case "latest":
            guard let dir = recordings().first else { fail("No recordings yet.") }
            report(dir, json: json)
        case "show":
            guard rest.count > 1, let dir = find(rest[1]) else { fail("Which recording? See `yapsketch list`.") }
            report(dir, json: json)
        case "brief":
            guard let dir = rest.count > 1 ? find(rest[1]) : recordings().first else { fail("No such recording.") }
            guard let prompt = try? String(contentsOf: dir.appendingPathComponent("PROMPT.md"), encoding: .utf8) else {
                fail("Couldn't read \(dir.path)/PROMPT.md.")
            }
            print(prompt)
        case "list":
            let n = rest.firstIndex(of: "-n").flatMap { rest.indices.contains($0 + 1) ? Int(rest[$0 + 1]) : nil } ?? 20
            list(Array(recordings().prefix(n)), json: json)
        case "path":
            guard let dir = rest.count > 1 ? find(rest[1]) : recordings().first else { fail("No such recording.") }
            print(dir.path)
        case "frames":
            guard rest.count > 2, let dir = find(rest[1]) else { fail("Usage: yapsketch frames <recording> <n|mm:ss> [--count N]") }
            let count = rest.firstIndex(of: "--count").flatMap { rest.indices.contains($0 + 1) ? Int(rest[$0 + 1]) : nil } ?? 8
            frames(dir, at: rest[2], count: min(max(count, 2), 24))
        case "reprocess":
            guard rest.count > 1, let dir = find(rest[1]) else { fail("Which recording? See `yapsketch list`.") }
            reprocess(dir, jev: rest.contains("--jev"))
        default:
            print(usage)
        }
        exit(0)
    }

    // MARK: Recordings

    /// Recording folders with a report, newest first.
    static func recordings() -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: AppDelegate.sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("REPORT.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// A recording by its id, folder name (or its start), or path.
    static func find(_ name: String) -> URL? {
        let path = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: path.appendingPathComponent("REPORT.md").path) { return path }
        let all = recordings()
        return all.first { id($0) == name.lowercased() } ?? all.first { $0.lastPathComponent == name }
            ?? all.first { $0.lastPathComponent.hasPrefix(name) }
    }

    /// A short, stable id for a recording, easy for an agent to type: four letters and digits
    /// from its folder name (FNV-1a, so it never changes).
    static func id(_ dir: URL) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in dir.lastPathComponent.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let digits = Array("abcdefghjkmnpqrstuvwxyz23456789")  // no 0/o, 1/l/i
        return String((0..<4).map { k in digits[Int(hash >> (k * 5)) % digits.count] })
    }

    /// The report with image paths made absolute, so they can be opened from anywhere.
    private static func absoluteReport(_ dir: URL) -> String {
        let report = (try? String(contentsOf: dir.appendingPathComponent("REPORT.md"), encoding: .utf8)) ?? ""
        return report.replacingOccurrences(of: "](shots/", with: "](\(dir.path)/shots/")
            .replacingOccurrences(of: "`recording.mp4`", with: "`\(dir.path)/recording.mp4`")
    }

    private static func report(_ dir: URL, json: Bool) {
        let markdown = absoluteReport(dir)
        if json {
            let images = markdown.split(separator: "\n").compactMap { line -> String? in
                guard let open = line.range(of: "]("), line.hasPrefix("!["), line.hasSuffix(")") else { return nil }
                return String(line[open.upperBound..<line.index(before: line.endIndex)])
            }
            emit(["recording": id(dir), "folder": dir.path, "report": markdown, "images": images])
        } else {
            print("Recording \(id(dir)) (folder: \(dir.path))\n")
            print(markdown)
        }
    }

    private static func list(_ dirs: [URL], json: Bool) {
        let rows: [[String: String]] = dirs.map { dir in
            let summary = RecordingSummary.load(dir)
            let start = summary?.plainNarration ?? ""
            return [
                "recording": id(dir), "length": summary?.length ?? "",
                "starts": start.count > 90 ? String(start.prefix(90)) + "…" : start, "folder": dir.path,
            ]
        }
        if json {
            emit(rows)
            return
        }
        for row in rows {
            guard let recording = row["recording"], let length = row["length"], let start = row["starts"] else { continue }
            print("\(recording)  \(length)  \(start)")
        }
        if rows.isEmpty { print("No recordings yet.") }
    }

    private static func reprocess(_ dir: URL, jev: Bool) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            guard let session = try? Session(existing: dir) else { fail("Couldn't open \(dir.path).") }
            var processor = PostProcessor(session: session, refineTranscript: true) { print($0) }
            processor.smartPictures = jev
            let out = await processor.run()
            print(out.reportURL.path)
            done.signal()
        }
        done.wait()
    }

    /// A contact sheet of `count` frames across marker [n]'s point (from a second before it to a
    /// second after), or across the four seconds around a moment (`mm:ss`), in `frames/`.
    private static func frames(_ dir: URL, at target: String, count: Int) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            guard let session = try? Session(existing: dir) else { fail("Couldn't open \(dir.path).") }
            let asset = AVURLAsset(url: session.videoURL)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var span: ClosedRange<Double>
            var name: String
            let clock = target.split(separator: ":").compactMap { Double($0) }
            if target.contains(":"), clock.count == 2 {
                let t = clock[0] * 60 + clock[1]
                span = (t - 2)...(t + 2)
                name = String(format: "%02dm%04.1fs", Int(clock[0]), clock[1])
            } else if let n = Int(target.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))), let s = Self.span(of: n, dir, session) {
                span = s
                name = "point-\(n)"
            } else {
                fail("No [\(target)] in that recording: give a marker number from its report, or a time as mm:ss.")
            }
            span = max(0, span.lowerBound)...max(max(0, span.lowerBound), min(span.upperBound, duration - 0.05))
            let times = (0..<count).map { span.lowerBound + (span.upperBound - span.lowerBound) * Double($0) / Double(count - 1) }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 800, height: 800)
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
            var tiles: [(t: Double, image: CGImage)] = []
            for await result in gen.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
                if let image = try? result.image { tiles.append((result.requestedTime.seconds, image)) }
            }
            tiles.sort { $0.t < $1.t }
            let out = dir.appendingPathComponent("frames/\(name).jpg")
            try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Two to a row (three when there are many), big enough to read once scaled down.
            let columns = count > 12 ? 3 : 2
            guard let sheet = Filmstrip.sheet(tiles, columns: columns, maxWidth: Double(columns) * 806 + 6),
                let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { fail("Couldn't read frames from \(session.videoURL.path).") }
            CGImageDestinationAddImage(dest, sheet, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { fail("Couldn't write \(out.path).") }
            print(out.path)
            done.signal()
        }
        done.wait()
    }

    /// When marker [n]'s point was, from the analysis, a second either side (with the marks
    /// made for it).
    private static func span(of n: Int, _ dir: URL, _ session: Session) -> ClosedRange<Double>? {
        guard let p = PointFinder.load(from: dir)?.points?.first(where: { $0.n == n }) else { return nil }
        let marks = session.events.filter { e in (p.marks ?? []).contains { abs($0 - e.t) < 0.001 } }
        let from = ([p.start] + marks.map { $0.t0 ?? $0.t }).min()!
        let to = ([p.end] + marks.map(\.t)).max()!
        return (from - 1)...(to + 1)
    }

    private static func emit(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    // MARK: Install

    /// Puts a `yapsketch` wrapper in ~/.local/bin that runs this app's executable, unless
    /// one that runs it is already there. Called at launch, so moving the app fixes itself.
    static func install() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let target = bin.appendingPathComponent("yapsketch")
        let script = "#!/bin/sh\n# YapSketch's command-line tool (installed by the app).\nYAPSKETCH_CLI=1 exec \"\(exe)\" \"$@\"\n"
        if (try? String(contentsOf: target, encoding: .utf8)) == script { return }
        // Don't replace something else that happens to be called yapsketch.
        if let existing = try? String(contentsOf: target, encoding: .utf8), !existing.contains("installed by the app") { return }
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        do {
            try script.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            Log.info("installed \(target.path)")
        } catch {
            Log.info("couldn't install \(target.path): \(error.localizedDescription)")
        }
    }
}
