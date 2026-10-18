import AVFoundation
import Foundation
import Speech

/// Live on-device transcription of the microphone stream. Partial results drive
/// the burned-in captions; final results become timestamped transcript segments.
final class AppleSpeech {
    /// Current caption text. Called on the main queue.
    var onPartial: ((String) -> Void)?
    /// A finished, timestamped piece of speech. Called on the main queue.
    var onSegment: ((TranscriptSegment) -> Void)?
    /// Live recognition can't work (e.g. Dictation is off). Called on the main queue.
    var onUnavailable: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "yapsketch.speech")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var requestStart: Double = 0
    private var clock: (() -> Double)?
    private var running = false

    /// Recognition tasks are rotated so a single utterance can't grow unbounded.
    private let maxTaskDuration: Double = 45

    init() {
        recognizer = Self.makeRecognizer()
    }

    /// Picks a recognizer for the user's preferred language. `Locale.current` can carry
    /// region overrides (e.g. `en_US@rg=sezzzz`) that the recognizer doesn't understand.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales()
        let wanted = Locale.preferredLanguages.map { Locale(identifier: $0) } + [Locale(identifier: "en-US")]
        for locale in wanted {
            let id = locale.identifier(.bcp47)
            if let match = supported.first(where: { $0.identifier(.bcp47) == id })
                ?? supported.first(where: {
                    $0.language.languageCode == locale.language.languageCode
                }), let r = SFSpeechRecognizer(locale: match)
            {
                return r
            }
        }
        return nil
    }

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    var isAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && (recognizer?.isAvailable ?? false)
    }

    func start(clock: @escaping () -> Double) {
        Log.info(
            "speech: auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) locale=\(recognizer?.locale.identifier ?? "none") available=\(recognizer?.isAvailable ?? false) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)"
        )
        queue.async {
            self.clock = clock
            self.running = true
            self.beginRequest()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.request?.endAudio()
            self.request = nil
        }
    }

    /// Feed a microphone buffer. Safe to call from any queue.
    func append(_ sb: CMSampleBuffer) {
        queue.async {
            guard self.running, let request = self.request else { return }
            request.appendAudioSampleBuffer(sb)
            if let clock = self.clock, clock() - self.requestStart > self.maxTaskDuration {
                self.rotate()
            }
        }
    }

    private func rotate() {
        request?.endAudio()  // the old task still delivers its final result
        beginRequest()
    }

    private func beginRequest() {
        guard running, let recognizer, recognizer.isAvailable else {
            Log.info("speech: recognizer unavailable, live captions off")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let start = clock?() ?? 0
        request = req
        requestStart = start

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    DispatchQueue.main.async { self.onPartial?(text) }
                }
                if result.isFinal {
                    let segs = Self.split(result.bestTranscription, offset: start)
                    DispatchQueue.main.async { segs.forEach { self.onSegment?($0) } }
                    self.queue.async { if self.request === req { self.rotate() } }
                }
            }
            if let error {
                // Typically "no speech detected" after silence; start over if still recording.
                // The small delay keeps a persistent failure from spinning.
                let ns = error as NSError
                if ns.code != 1110 && ns.code != 216 { Log.info("speech: \(ns.domain) \(ns.code) \(ns.localizedDescription)") }
                if ns.domain == "kLSRErrorDomain" && ns.code == 201 {
                    // "Siri and Dictation are disabled": retrying won't help.
                    self.queue.async {
                        self.running = false
                        self.request = nil
                    }
                    DispatchQueue.main.async { self.onUnavailable?(ns.localizedDescription) }
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 0.3) { if self.request === req { self.beginRequest() } }
            }
        }
    }

    /// Splits a transcription into sentence-ish segments using punctuation and pauses.
    static func split(_ t: SFTranscription, offset: Double) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var words: [String] = []
        var segStart: Double?
        var lastEnd: Double = 0

        func flush() {
            guard let s = segStart, !words.isEmpty else { return }
            out.append(TranscriptSegment(start: offset + s, end: offset + lastEnd, text: words.joined(separator: " ")))
            words = []
            segStart = nil
        }

        for seg in t.segments {
            if segStart != nil, seg.timestamp - lastEnd > 0.9 { flush() }
            if segStart == nil { segStart = seg.timestamp }
            words.append(seg.substring)
            lastEnd = seg.timestamp + seg.duration
            if let last = seg.substring.last, ".?!".contains(last) { flush() }
        }
        flush()

        // No usable word timings: keep the whole thing as one segment.
        if out.isEmpty, !t.formattedString.isEmpty {
            out.append(TranscriptSegment(start: offset, end: offset, text: t.formattedString))
        }
        return out
    }
}
