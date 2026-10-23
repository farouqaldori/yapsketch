import AVFoundation
import Foundation

/// `yapsketch <command>`: the recordings for coding agents (and people) on the command line.
/// The app's own executable answers these; `yapsketch` on the PATH is a small wrapper the
/// app installs that runs it.
enum CLI {
    static let commands: Set<String> = ["latest", "list", "show", "brief", "path", "frames", "reprocess", "help", "--help", "-h"]

    static let usage = """
        yapsketch: YapSketch screen recordings: what the user said and did while showing their
        screen, each at its time, with a picture wherever they drew or circled with the pointer.

          yapsketch latest            the newest recording's report
          yapsketch show <recording>  a recording's report (its id from `list`, or a path)
          yapsketch brief [recording] what's copied when a recording ends (the report, shorter)
          yapsketch list [-n N]       recent recordings: when, how long, how they start
          yapsketch path [recording]  a recording's folder (the newest by default)
          yapsketch frames <recording> <mm:ss>
                                     the screen at that moment, full size, and prints its path
          yapsketch frames <recording> <mm:ss>-<mm:ss> [--every <seconds>]
                                     frames across a stretch (6 by default, 12 at most), two to
                                     a row with their times, in one picture, and prints its path
          yapsketch reprocess <recording>
                                     build a report again

        Reports are Markdown: what was said and done, each line at its time (minutes:seconds).
        Image paths are absolute: open each image to see what the user showed. A picture's
        number is in a coral badge next to what they drew or circled, and the spot the pointer
        circled is lit.
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
            guard rest.count > 2, let dir = find(rest[1]) else {
                fail("Usage: yapsketch frames <recording> <mm:ss> or <mm:ss>-<mm:ss> [--every <seconds>]")
            }
            let every = rest.firstIndex(of: "--every").flatMap { rest.indices.contains($0 + 1) ? Double(rest[$0 + 1].trimmingCharacters(in: ["s"])) : nil }
            frames(dir, at: rest[2], every: every)
        case "reprocess":
            guard rest.count > 1, let dir = find(rest[1]) else { fail("Which recording? See `yapsketch list`.") }
            reprocess(dir)
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

    private static func reprocess(_ dir: URL) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            guard let session = try? Session(existing: dir) else { fail("Couldn't open \(dir.path).") }
            let processor = PostProcessor(session: session, refineTranscript: true) { print($0) }
            let out = await processor.run()
            print(out.reportURL.path)
            done.signal()
        }
        done.wait()
    }

    /// Seconds from `01:23.4`, `1:23`, `83.4` or `1:02:03`.
    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + $1! }
    }

    /// The screen at a moment (`mm:ss`), full size; or frames across a stretch (`mm:ss-mm:ss`),
    /// two to a row with their times, in one picture. Saved in `frames/`.
    private static func frames(_ dir: URL, at target: String, every: Double?) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            guard let session = try? Session(existing: dir) else { fail("Couldn't open \(dir.path).") }
            let asset = AVURLAsset(url: session.videoURL)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let ends = target.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(ends.count), let from = seconds(ends[0]), let to = seconds(ends[ends.count - 1]) else {
                fail("Give a time as minutes:seconds (01:23.4), or a stretch (01:20-01:30).")
            }
            guard to >= from else { fail("That stretch ends before it starts.") }
            guard from < duration else { fail("The recording is only \(Fmt.clock(duration)) long.") }
            let last = max(0, duration - 0.05)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = session.display.size
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
            let folder = dir.appendingPathComponent("frames", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func name(_ t: Double) -> String { Fmt.clock(t).replacingOccurrences(of: ":", with: "m") + "s" }

            if ends.count == 1 {
                let t = min(from, last)
                guard let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else {
                    fail("Couldn't read the video at \(Fmt.clock(t)).")
                }
                let out = folder.appendingPathComponent("\(name(t)).jpg")
                guard PostProcessor.write(image, to: out) else { fail("Couldn't write \(out.path).") }
                print("The screen at \(Fmt.clock(t)) (\(image.width)×\(image.height)): \(out.path)")
                done.signal()
                return
            }

            let end = min(to, last)
            // Six across the stretch, or one every `every` seconds; twelve at most.
            let step = max(0.1, every ?? max(0.2, (end - from) / 5))
            let count = min(12, Int(((end - from) / step + 0.001).rounded(.down)) + 1)
            let times = (0..<count).map { from + Double($0) * step }
            var tiles: [(t: Double, image: CGImage)] = []
            for await result in gen.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
                if let image = try? result.image { tiles.append((result.requestedTime.seconds, image)) }
            }
            tiles.sort { $0.t < $1.t }
            guard let sheet = Filmstrip.sheet(tiles, columns: 2, maxWidth: 2 * 1000 + 18) else {
                fail("Couldn't read frames from \(session.videoURL.path).")
            }
            let out = folder.appendingPathComponent("\(name(from))-\(name(end)).jpg")
            guard PostProcessor.write(sheet, to: out) else { fail("Couldn't write \(out.path).") }
            let spacing = String(format: "%.1f", step)
            let shown = "\(tiles.count) frames from \(Fmt.clock(tiles.first?.t ?? from)) to \(Fmt.clock(tiles.last?.t ?? end))"
            print("\(shown), one every \(spacing) s, two to a row with their times: \(out.path)")
            done.signal()
        }
        done.wait()
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
