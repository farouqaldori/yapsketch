import AVFoundation
import AppKit
import Carbon

@MainActor
final class Dictation {
    /// `priming`: fn is down but might still be fn+key, so the microphone is already on and
    /// nothing shows yet. Nothing said in those first moments is lost.
    private enum State { case idle, priming, listening, working }

    private let parakeet: ParakeetLive
    private let hotkeys: Hotkeys
    private let pill = DictationPill()
    private var engine: AVAudioEngine?
    private var micChanged: NSObjectProtocol?
    private var reopen: DispatchWorkItem?
    private var quiet: DispatchWorkItem?
    private var primeTimeout: DispatchWorkItem?
    private var state = State.idle
    private var pressedAt = Date()
    /// Tapped rather than held: keeps listening until the next tap.
    private var locked = false
    private var escape: UInt32?
    /// 16 kHz mono.
    private var samples: [Float] = []
    private var segments: [TranscriptSegment] = []
    private var live = false
    private var heard = false
    private var saved: (partial: ((String) -> Void)?, segment: ((TranscriptSegment) -> Void)?)
    private var work: Task<Void, Never>?

    var isBusy: Bool { state != .idle && state != .priming }
    /// The last word often trails past the key coming up: keep listening this long after.
    private static let tail = 0.35

    init(parakeet: ParakeetLive, hotkeys: Hotkeys) {
        self.parakeet = parakeet
        self.hotkeys = hotkeys
        pill.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: The shortcut

    /// fn went down: listen already, in case it's dictation.
    func prime() {
        guard state == .idle, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        samples = []
        heard = false
        guard openMicrophone() == nil else { return }
        state = .priming
        // fn always turns into a press or a combo; this is only in case neither comes.
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.unprime() } }
        primeTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        if CloudSpeech.selected() == nil { LocalSpeech.shared.prepare() }
    }

    /// It was fn+key after all.
    func unprime() {
        guard state == .priming else { return }
        closeMicrophone()
        samples = []
        state = .idle
    }

    func pressed() {
        switch state {
        case .idle, .priming: start()
        case .listening: if locked { finish() }
        case .working: break
        }
    }

    /// Held for a moment: push-to-talk, done on release. A quick tap: stays on.
    func released() {
        guard state == .listening, !locked else { return }
        if Date().timeIntervalSince(pressedAt) >= 0.3 { finish() } else { locked = true }
    }

    // MARK: Listening

    private func start() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            pill.listening()
            pill.done("Needs microphone access", ok: false)
            return
        }
        let primed = state == .priming
        primeTimeout?.cancel()
        if !primed {
            samples = []
            heard = false
        }
        segments = []
        locked = false
        pressedAt = Date()
        live = CloudSpeech.selected() == nil && parakeet.isAvailable
        if live {
            saved = (parakeet.onPartial, parakeet.onSegment)
            parakeet.onPartial = { [weak self] t in self.map { $0.pill.text(($0.segments.map(\.text) + [t]).joined(separator: " ")) } }
            parakeet.onSegment = { [weak self] seg in self?.segments.append(seg) }
            parakeet.start(clock: { 0 })
        }
        if !primed, let trouble = openMicrophone() {
            stopLive()
            pill.listening()
            pill.done(trouble, ok: false)
            return
        }
        state = .listening
        pill.listening()
        if live, !samples.isEmpty { parakeet.append(samples: samples) }
        if !samples.isEmpty { nowHearing() }
        escape = hotkeys.register(Hotkeys.Combo(keyCode: kVK_Escape, modifiers: 0, display: "⎋")) { [weak self] in self?.cancel() }
        if CloudSpeech.selected() == nil, !live { LocalSpeech.shared.prepare() }
        Log.info(
            "dictation: listening (\(live ? "live" : CloudSpeech.selected().map { "\($0.name) via \($0.providerName)" } ?? "on this Mac"))"
        )
    }

    /// Starts the microphone; what went wrong otherwise.
    private func openMicrophone() -> String? {
        let engine = AVAudioEngine()
        Microphone.use(on: engine)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { return "No microphone" }
        // A stereo or multi-input microphone: all of it, mixed down.
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var given = false
            converter.convert(to: out, error: nil) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            let rms = (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            // In decibels, like the recording toolbar's meter: speech moves the bars, not just shouting.
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 40))
            DispatchQueue.main.async { self?.received(chunk, level: level) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.info("dictation: audio engine failed: \(error.localizedDescription)")
            return "Microphone unavailable"
        }
        self.engine = engine
        // Headphones connected, the default input changed: the engine stops, so it's started
        // again on the microphone there is now, keeping what was heard.
        micChanged = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.microphoneChanged() }
        }
        return nil
    }

    private func closeMicrophone() {
        reopen?.cancel()
        reopen = nil
        if let micChanged { NotificationCenter.default.removeObserver(micChanged) }
        micChanged = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func microphoneChanged() {
        guard engine != nil else { return }
        // Connecting Bluetooth headphones sends a burst of these: once it's settled.
        reopen?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.engine != nil else { return }
                self.closeMicrophone()
                if let trouble = self.openMicrophone() {
                    Log.info("dictation: microphone changed and couldn't start again (\(trouble))")
                    if self.state == .listening { self.finish() } else { self.unprime() }
                } else {
                    Log.info("dictation: microphone changed, listening on")
                }
            }
        }
        reopen = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func received(_ chunk: [Float], level: Float) {
        // Still listening through the tail after the key comes up.
        guard engine != nil else { return }
        samples += chunk
        guard state != .priming else { return }
        if !heard { nowHearing() }
        if state == .listening { pill.level(level) }
        if live { parakeet.append(samples: chunk) }
    }

    /// The start sound once the microphone is actually live, so no word is lost; then other
    /// sound goes quiet (after the start sound, so it's heard).
    private func nowHearing() {
        guard !heard else { return }
        heard = true
        Sounds.play(.dictateOn)
        let w = DispatchWorkItem { MainActor.assumeIsolated { QuietOutput.begin() } }
        quiet = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func soundBack() {
        quiet?.cancel()
        quiet = nil
        QuietOutput.end()
    }

    private func stopListening() {
        closeMicrophone()
        soundBack()
        if let escape { hotkeys.unregister(escape) }
        escape = nil
    }

    private func stopLive() {
        guard live else { return }
        live = false
        Task {
            await parakeet.finish()
            parakeet.onPartial = saved.partial
            parakeet.onSegment = saved.segment
        }
    }

    func cancel() {
        switch state {
        case .priming:
            unprime()
        case .listening:
            stopListening()
            stopLive()
            state = .idle
            pill.hide()
            Log.info("dictation: cancelled")
        case .working:
            work?.cancel()
            work = nil
            if let escape { hotkeys.unregister(escape) }
            escape = nil
            state = .idle
            pill.hide()
            Log.info("dictation: cancelled while transcribing")
        case .idle:
            break
        }
    }

    // MARK: Done talking

    private func finish() {
        guard state == .listening else { return }
        state = .working
        // Sound back first, so the stop sound is heard.
        soundBack()
        // The moment you let go, even though listening carries on through the tail.
        Sounds.play(.dictateOff)
        guard Double(samples.count) / 16_000 >= 0.3 else {
            stopListening()
            stopLive()
            state = .idle
            pill.done("Too short to transcribe", ok: false)
            return
        }
        pill.working()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tail) { [weak self] in self?.transcribe() }
    }

    private func transcribe() {
        stopListening()
        let duration = Double(samples.count) / 16_000
        let heardSamples = samples
        let wasLive = live
        // Nothing but silence (or a microphone sending nothing): no point asking a model,
        // which might make words up.
        if let nothing = SpeechCheck.nothingHeard(in: heardSamples) {
            stopLive()
            state = .idle
            pill.done(nothing, ok: false)
            Log.info("dictation: \(nothing.lowercased()), not transcribed")
            return
        }
        let audio = DictationHistory.newAudioURL()
        escape = hotkeys.register(Hotkeys.Combo(keyCode: kVK_Escape, modifiers: 0, display: "⎋")) { [weak self] in self?.cancel() }
        work = Task {
            DictationHistory.writeWAV(heardSamples, to: audio)
            var heard = (text: "", model: ModelStore.current()?.name ?? "on this Mac", trouble: String?.none)
            if wasLive {
                await parakeet.finish()
                parakeet.onPartial = saved.partial
                parakeet.onSegment = saved.segment
                live = false
                heard.text = segments.map(\.text).joined(separator: " ")
            }
            if heard.text.isEmpty { heard = await Self.words(in: audio, duration: duration) }
            let raw = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = TextCleanup.apply(raw)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: audio)
                return
            }
            if let escape { hotkeys.unregister(escape) }
            escape = nil
            work = nil
            guard !final.isEmpty else {
                state = .idle
                if let trouble = heard.trouble {
                    // The provider failed and nothing on this Mac could stand in: keep it to try again.
                    DictationHistory.add(text: "", raw: "", model: heard.model, duration: duration, audio: audio, failure: trouble)
                    pill.done("\(trouble). Saved in History", ok: false)
                    Log.info("dictation: kept for later (\(trouble))")
                } else {
                    pill.done("Nothing heard", ok: false)
                    try? FileManager.default.removeItem(at: audio)
                }
                return
            }
            Paster.deliver(final)
            pill.done("Copied" + (heard.trouble.map { " · \($0)" } ?? ""))
            DictationHistory.add(text: final, raw: raw, model: heard.model, duration: duration, audio: audio)
            Log.info(String(format: "dictation: %d words in %.1fs of speech (%@)", final.split(separator: " ").count, duration, heard.model))
            state = .idle
        }
    }

    /// Tries the chosen cloud model briefly, then this Mac's model.
    static func words(in audio: URL, duration: Double) async -> (text: String, model: String, trouble: String?) {
        var trouble: String?
        if let cloud = CloudSpeech.selected() {
            let since = Date()
            if let segments = await CloudSpeech.transcribe(audio: audio, model: cloud, deadline: min(60, 15 + duration * 0.5)) {
                let text = segments.map(\.text).joined(separator: " ")
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { return (text, "\(cloud.name) via \(cloud.providerName)", nil) }
            } else {
                trouble = (ProviderHTTP.trouble(for: cloud.providerID, since: since) ?? .offline).sentence(cloud.providerName)
            }
        }
        let local = ModelStore.current()?.name ?? "on this Mac"
        if let p = await LocalSpeech.shared.transcribe(audio: audio) {
            let text = p.segments.map(\.text).joined(separator: " ")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { return (text, local, trouble) }
        }
        return ("", CloudSpeech.selected().map { "\($0.name) via \($0.providerName)" } ?? local, trouble)
    }
}

enum LiveWords {
    static var shown: Bool { UserDefaults.standard.object(forKey: "showWords") == nil || UserDefaults.standard.bool(forKey: "showWords") }
}

/// Past dictations, kept as long as recordings are.
enum DictationHistory {
    struct Entry: Codable, Identifiable, Hashable {
        var id: String
        var date: Date
        var text: String
        var raw: String
        var model: String
        var duration: Double
        var audio: String
        /// Why there's no text yet (the provider failed and nothing on this Mac could stand in).
        var failure: String?
    }

    static var folder: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/YapSketch/Dictations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func newAudioURL() -> URL { folder.appendingPathComponent(stamp.string(from: Date()) + ".wav") }

    static func add(text: String, raw: String, model: String, duration: Double, audio: URL, failure: String? = nil) {
        let id = audio.deletingPathExtension().lastPathComponent
        let entry = Entry(
            id: id, date: Date(), text: text, raw: raw, model: model, duration: duration, audio: audio.lastPathComponent, failure: failure)
        save(entry)
    }

    /// Transcribes an entry kept without text again and fills it in. False if it still has no text.
    @MainActor
    static func retry(_ e: Entry) async -> Bool {
        let heard = await Dictation.words(in: folder.appendingPathComponent(e.audio), duration: e.duration)
        let raw = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = TextCleanup.apply(raw)
        var entry = e
        entry.failure = final.isEmpty ? (heard.trouble ?? e.failure) : nil
        entry.text = final
        entry.raw = raw
        entry.model = heard.model
        save(entry)
        return !final.isEmpty
    }

    /// Your own correction of what was pasted.
    static func update(_ e: Entry, text: String) {
        var entry = e
        entry.text = text
        save(entry)
    }

    private static func save(_ entry: Entry) {
        let id = entry.id
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(entry).write(to: folder.appendingPathComponent(id + ".json"))
        NotificationCenter.default.post(name: .yapSketchDictationsChanged, object: nil)
    }

    static func all() -> [Entry] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ e: Entry, notify: Bool = true) {
        try? FileManager.default.trashItem(at: folder.appendingPathComponent(e.id + ".json"), resultingItemURL: nil)
        try? FileManager.default.trashItem(at: folder.appendingPathComponent(e.audio), resultingItemURL: nil)
        if notify { NotificationCenter.default.post(name: .yapSketchDictationsChanged, object: nil) }
    }

    /// 16 kHz mono 16-bit WAV (what every speech service takes).
    static func writeWAV(_ samples: [Float], to url: URL) {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
            let ch = buf.floatChannelData
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            return
        }
        try? file.write(from: buf)
    }
}

extension Notification.Name {
    static let yapSketchDictationsChanged = Notification.Name("yapSketchDictationsChanged")
}
