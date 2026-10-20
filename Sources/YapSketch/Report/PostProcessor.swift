import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a finished recording into REPORT.md: my narration with a numbered screenshot
/// at each point I make, plus the transcript and raw events.
struct PostProcessor {
    let session: Session
    /// Transcribe the whole recording again after it ends (more accurate than the live words).
    let refineTranscript: Bool
    /// Let Jev divide the words into points, match the marks to them and pick their moments
    /// (sends the words and some frames to the Jev provider).
    var smartPictures = false
    var progress: (String) -> Void = { _ in }

    /// How long each step takes, in the log (a step ends when the next one starts).
    private final class Steps {
        var current: (name: String, start: CFAbsoluteTime)?
        let start = CFAbsoluteTimeGetCurrent()
        func next(_ name: String?) {
            let now = CFAbsoluteTimeGetCurrent()
            if let c = current { Log.info(String(format: "step %@: %.1fs", c.name, now - c.start)) }
            current = name.map { ($0, now) }
            if name == nil { Log.info(String(format: "processing took %.1fs", now - start)) }
        }
    }
    private let steps = Steps()

    func step(_ message: String) {
        steps.next(message)
        progress(message)
    }

    struct Output: Sendable {
        let reportURL: URL
        let transcriptSource: String
        /// What didn't work, for the pill: "Opper is out of credits".
        var note: String?
    }

    func run() async -> Output {
        let started = Date()
        let dir = session.dir
        let asset = AVURLAsset(url: session.videoURL)
        let duration = (try? await asset.load(.duration).seconds) ?? session.now()

        var transcript = session.liveTranscript
        var source = transcript.isEmpty ? "none" : "Apple on-device (live)"
        if refineTranscript, let audio = await audioSource(asset: asset) {
            step("Transcribing…")
            if let cloud = CloudSpeech.selected(), let segs = await CloudSpeech.transcribe(audio: audio, model: cloud), !segs.isEmpty {
                transcript = segs
                source = "\(cloud.name) via \(cloud.providerName)"
            } else if let p = await ParakeetOffline.transcribe(audio: audio), !p.segments.isEmpty {
                transcript = p.segments
                source = ModelStore.current()?.name ?? p.model
            }
        }
        transcript = TextCleanup.apply(transcript)
        writeJSON(transcript, to: dir.appendingPathComponent("transcript.json"))
        try? srt(transcript).write(to: dir.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)

        // Events are rewritten sorted because async AX lookups land late.
        // Moving the mouse just before or after drawing is getting into position, not pointing.
        let drawingTimes = session.events.filter { $0.kind == .annotation || $0.kind == .textNote }
            .map { (($0.t0 ?? $0.t) - 2)...($0.t + 2) }
        let gestures = PointerGestures.find(
            session.pointerSamples, excluding: drawingTimes,
            clicks: session.events.filter { $0.kind == .click }.map(\.t))
        let events = (session.events.filter { $0.kind != .gesture } + gestures).sorted { $0.t < $1.t }
        let lines = events.compactMap { e -> String? in
            guard let d = try? Self.encoder.encode(e) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: session.eventsURL, atomically: true, encoding: .utf8)

        // A previous run's answers are kept where the question is the same.
        let words = transcript.flatMap { $0.words ?? [] }
        let app = events.last(where: { $0.kind == .appSwitch || $0.kind == .window })
        let marks = events.filter { [.annotation, .textNote, .gesture].contains($0.kind) }
        let previous = PointFinder.load(from: dir)
        let saved = previous.map { $0.points ?? $0.segments } ?? []
        var fresh: SessionAnalysis?
        if smartPictures {
            step("Analyzing…")
            let screen = [app?.app, app?.window].compactMap { $0 }.joined(separator: " — ")
            fresh = await PointFinder(words: words, screen: screen, display: session.display.size, marks: marks, previous: previous).run()
        }
        let analysis = fresh ?? previous
        let segments =
            analysis?.segments
            ?? transcript.enumerated().map {
                SegmentAnalysis(index: $0.offset, start: $0.element.start, end: $0.element.end, text: $0.element.text)
            }
        // Small frames and screen changes were noted while recording.
        let frameLog = FrameLog.load(from: dir)
        // Marks on different screens each need their own picture, so a point spanning them is divided there.
        let screens = frameLog.map { ScreenSplit(session: session, events: events, frames: $0) }
        var points: [SegmentAnalysis]
        if let fresh, let made = fresh.points {
            points = made
            if let screens {
                points = PointFinder.divide(points, marks: marks, apart: screens.apart(points, marks: marks), words: words, splits: [])
            }
        } else {
            let assigned = PointFinder.assign(
                marks, to: PointFinder.points(segments, saved: [previous?.segments ?? [], saved]), judged: analysis?.marks ?? [])
            points = PointFinder.divide(
                assigned, marks: marks, apart: (screens?.apart(assigned, marks: marks) ?? []) + (analysis?.apart ?? []), words: words,
                splits: analysis?.splits ?? [])
        }

        step("Taking screenshots…")
        let shots = await pictures(
            asset: asset, points: points, events: events, duration: duration, words: words, frames: frameLog, previous: saved)
        for k in points.indices { points[k].n = shots[k]?.n }
        var record = analysis ?? SessionAnalysis(segments: segments)
        record.version = SessionAnalysis().version
        record.points = points
        PointFinder.write(record, to: dir)

        steps.next("Report")
        let builder = ReportBuilder(
            session: session, duration: duration, events: events, points: points,
            shots: shots, transcriptSource: source, segmentedBy: (analysis?.splits.isEmpty ?? true) ? nil : "Jev")
        let reportURL = dir.appendingPathComponent("REPORT.md")
        try? builder.markdown().write(to: reportURL, atomically: true, encoding: .utf8)
        try? builder.brief().write(to: dir.appendingPathComponent("PROMPT.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("audio-from-video.m4a"))
        steps.next(nil)
        return Output(reportURL: reportURL, transcriptSource: source, note: note(since: started, transcribedBy: source))
    }

    /// The first thing a provider got wrong while this ran, if the report is the poorer for it:
    /// cloud speech that fell back to this Mac, or Jev that didn't answer.
    private func note(since started: Date, transcribedBy source: String) -> String? {
        if refineTranscript, let cloud = CloudSpeech.selected(), source != "\(cloud.name) via \(cloud.providerName)" {
            let trouble = ProviderHTTP.trouble(for: cloud.providerID, since: started) ?? .offline
            return trouble.sentence(cloud.providerName)
        }
        if smartPictures, let route = Jev.route(), let trouble = ProviderHTTP.trouble(for: route.provider.id, since: started) {
            return trouble.sentence(route.provider.name)
        }
        return nil
    }

    /// The separate mic track, or, if that file is unusable (e.g. the app was killed
    /// mid-recording), the audio track exported from the video.
    private func audioSource(asset: AVURLAsset) async -> URL? {
        let mic = session.micURL
        if let tracks = try? await AVURLAsset(url: mic).loadTracks(withMediaType: .audio), !tracks.isEmpty { return mic }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
            let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { return nil }
        let out = session.dir.appendingPathComponent("audio-from-video.m4a")
        try? FileManager.default.removeItem(at: out)
        do {
            try await export.export(to: out, as: .m4a)
            Log.info("mic.m4a unusable, transcribing the video's audio instead")
            return out
        } catch {
            Log.info("audio export failed: \(error.localizedDescription)")
            return nil
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? e.encode(value).write(to: url)
    }

    private func srt(_ segs: [TranscriptSegment]) -> String {
        segs.enumerated().map { i, s in
            "\(i + 1)\n\(Fmt.srt(s.start)) --> \(Fmt.srt(max(s.end, s.start + 0.8)))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

}
