import AVFoundation
import Foundation

/// Whole recordings and dictations transcribed on this Mac by the `yapsketch-asr` helper.
/// With a model that doesn't stream, the helper stays loaded between dictations (until it's
/// been idle as long as Settings says), so a dictation doesn't wait for the model to load.
// @unchecked: everything is touched on `queue`, one request at a time.
final class LocalSpeech: @unchecked Sendable {
    static let shared = LocalSpeech()

    struct Result {
        let segments: [TranscriptSegment]
        let model: String
    }

    private let queue = DispatchQueue(label: "yapsketch.local-speech", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var loadedModel: URL?
    private var lastUsed = Date()
    private var idleTimer: Timer?

    /// Kept loaded between uses: the model dictation runs on when it can't stream.
    private static var staysLoaded: Bool {
        CloudSpeech.selected() == nil && ModelStore.current()?.live == false
    }

    /// Loads the model ahead of time, when dictation will need it.
    func prepare() {
        guard Self.staysLoaded else { return }
        queue.async { _ = self.launch() }
    }

    /// Another model was chosen, or the custom words changed: the loaded one goes.
    func reload() {
        queue.async {
            self.stop()
            if Self.staysLoaded { _ = self.launch() }
        }
    }

    func transcribe(audio: URL) async -> Result? {
        let pcm: Data
        do { pcm = try Audio16k.floatData(audio) } catch {
            Log.info("local speech: audio decode failed: \(error)")
            return nil
        }
        return await transcribe(pcm: pcm)
    }

    /// Raw 16 kHz mono float samples.
    func transcribe(pcm: Data) async -> Result? {
        let seconds = Double(pcm.count / 4) / 16_000
        let words: [TranscriptSegment]? = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.run(pcm, seconds: seconds)) }
        }
        guard let words, let model = loadedModel ?? ParakeetLive.findModel() else {
            Log.info("local speech: transcription failed")
            return nil
        }
        return Result(segments: Audio16k.sentences(from: words), model: model.deletingPathExtension().lastPathComponent)
    }

    // MARK: The helper (on `queue`)

    private func run(_ pcm: Data, seconds: Double) -> [TranscriptSegment]? {
        guard launch(), let input, let process else { return nil }
        lastUsed = Date()
        let header: [String: Any] = ["samples": pcm.count / 4, "vocabulary": TextCleanup.customWords]
        guard var line = try? JSONSerialization.data(withJSONObject: header) else { return nil }
        line.append(0x0A)
        // A helper that hangs is stopped, which ends the wait below.
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true {
                Log.info("local speech: no answer in time, stopping the helper")
                process?.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60 + seconds, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try input.write(contentsOf: line)
            try input.write(contentsOf: pcm)
        } catch {
            stop()
            return nil
        }
        var words: [TranscriptSegment]?
        while let obj = nextLine() {
            guard let type = obj["type"] as? String else { continue }
            if type == "error" { Log.info("local speech: \(obj["message"] as? String ?? "error")") }
            guard type == "words", let items = obj["words"] as? [[String: Any]] else { continue }
            words = items.compactMap {
                guard let t0 = ($0["t0_ms"] as? NSNumber)?.doubleValue, let t1 = ($0["t1_ms"] as? NSNumber)?.doubleValue,
                    let text = $0["text"] as? String
                else { return nil }
                return TranscriptSegment(start: t0 / 1000, end: t1 / 1000, text: text)
            }
            break
        }
        lastUsed = Date()
        if words == nil || !Self.staysLoaded { stop() }
        return words
    }

    /// True once a helper with the current model is running.
    private func launch() -> Bool {
        let model = ParakeetLive.findModel()
        if let process, process.isRunning, loadedModel == model { return true }
        stop()
        guard let helper = ParakeetLive.helperURL, let model else { return false }
        let p = Process()
        p.executableURL = helper
        p.arguments = ["--serve", model.path]
        var env = ProcessInfo.processInfo.environment
        // Its Metal residency thread would wake every 5 ms for as long as the helper idles.
        env["GGML_METAL_NO_RESIDENCY"] = "1"
        p.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.info("local speech: helper failed to start: \(error)")
            return false
        }
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        pending = Data()
        loadedModel = model
        lastUsed = Date()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.watchIdle() } }
        Log.info("local speech: loading \(model.deletingPathExtension().lastPathComponent)")
        return true
    }

    private func stop() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        loadedModel = nil
    }

    /// The next JSON line from the helper; nil once it has exited.
    private func nextLine() -> [String: Any]? {
        while true {
            if let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return obj }
                continue
            }
            guard let output else { return nil }
            let data = output.availableData
            if data.isEmpty { return nil }
            pending.append(data)
        }
    }

    // MARK: Idle

    @MainActor
    private func watchIdle() {
        guard idleTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.queue.async { self?.unloadIfIdle() }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func unloadIfIdle() {
        let minutes = ParakeetLive.unloadAfterMinutes
        guard minutes > 0, process != nil, Date().timeIntervalSince(lastUsed) > Double(minutes) * 60 else { return }
        Log.info("local speech: model idle for \(minutes) min, unloading")
        stop()
    }
}
