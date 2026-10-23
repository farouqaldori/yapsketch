import AVFoundation
import Foundation

/// Turns a finished recording into its paste (PROMPT.md), report (REPORT.md) and History entry
/// (report.json): what I said and did in order, with a picture wherever I drew or pointed.
struct PostProcessor {
    let session: Session
    /// Transcribe the whole recording again after it ends (more accurate than the live words).
    let refineTranscript: Bool
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
            } else if let earlier = earlierTranscript() {
                // Made again (`yapsketch reprocess`) when neither works: the words it had.
                (transcript, source) = earlier
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

        let words = transcript.flatMap { $0.words ?? [] }
        step("Taking pictures…")
        let pictures = await pictures(asset: asset, events: events, duration: duration)
        let timeline = Timeline(words: words, segments: transcript, events: events, pictures: pictures)

        steps.next("Report")
        let builder = ReportBuilder(
            session: session, duration: duration, events: events, timeline: timeline, pictures: pictures, transcriptSource: source)
        let reportURL = dir.appendingPathComponent("REPORT.md")
        try? builder.markdown().write(to: reportURL, atomically: true, encoding: .utf8)
        try? builder.brief().write(to: dir.appendingPathComponent("PROMPT.md"), atomically: true, encoding: .utf8)
        try? builder.summary()?.write(to: dir.appendingPathComponent("report.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("audio-from-video.m4a"))
        steps.next(nil)
        return Output(reportURL: reportURL, transcriptSource: source, note: note(since: started, transcribedBy: source))
    }

    /// The words from when the report was last made, if they were timed word by word (better than
    /// the live captions).
    private func earlierTranscript() -> ([TranscriptSegment], String)? {
        guard let data = try? Data(contentsOf: session.dir.appendingPathComponent("transcript.json")),
            let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data),
            segments.contains(where: { !($0.words ?? []).isEmpty })
        else { return nil }
        let summary = (try? Data(contentsOf: session.dir.appendingPathComponent("report.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (segments, summary?["words"] as? String ?? "an earlier transcription")
    }

    /// What the cloud speech model got wrong, if the words came from this Mac instead.
    private func note(since started: Date, transcribedBy source: String) -> String? {
        guard refineTranscript, let cloud = CloudSpeech.selected(), source != "\(cloud.name) via \(cloud.providerName)" else { return nil }
        let trouble = ProviderHTTP.trouble(for: cloud.providerID, since: started) ?? .offline
        return trouble.sentence(cloud.providerName)
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
