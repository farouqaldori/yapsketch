import AVFoundation
import Foundation

protocol LiveTranscriber: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onSegment: ((TranscriptSegment) -> Void)? { get set }
    var onUnavailable: ((String) -> Void)? { get set }
    var isAvailable: Bool { get }
    var engineName: String { get }
    func start(clock: @escaping () -> Double)
    func append(_ sb: CMSampleBuffer)
    /// Stops and waits (briefly) for the last results to arrive.
    func finish() async
}

extension AppleSpeech: LiveTranscriber {
    var engineName: String { "Apple Dictation" }

    func finish() async {
        stop()
        try? await Task.sleep(nanoseconds: 700_000_000)
    }
}

/// Live captions from a streaming transcribe.cpp model, run in the bundled `yapsketch-asr`
/// helper process.
// @unchecked: its state changes on the main queue; audio is written on writeQueue.
final class ParakeetLive: LiveTranscriber, @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    var onSegment: ((TranscriptSegment) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let writeQueue = DispatchQueue(label: "yapsketch.asr.write")
    private var clock: (() -> Double)?
    /// Session time of the first audio sample sent; helper timestamps are relative to it.
    private var audioStart: Double?
    private var ready = false
    /// A recording is currently using the helper.
    private var active = false
    private var lastUsed = Date()
    private var idleTimer: Timer?

    /// Frees the model's memory after this many idle minutes (0 = never). The next recording
    /// loads it again.
    static var unloadAfterMinutes: Int {
        UserDefaults.standard.object(forKey: "modelUnloadMinutes") as? Int ?? 60
    }
    private var exited: CheckedContinuation<Void, Never>?

    var engineName: String { ModelStore.current()?.name ?? Self.findModel()?.deletingPathExtension().lastPathComponent ?? "?" }
    var isAvailable: Bool { Self.helperURL != nil && Self.liveModel != nil }

    static var helperURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/yapsketch-asr"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("yapsketch-asr"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `liveModelPath` overrides the model chosen in Settings, for development.
    static func findModel() -> URL? {
        if let custom = UserDefaults.standard.string(forKey: "liveModelPath"), !custom.isEmpty {
            let u = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return ModelStore.currentFile()
    }

    /// Live captions need a model that streams.
    static var liveModel: URL? {
        guard let m = findModel() else { return nil }
        if UserDefaults.standard.string(forKey: "liveModelPath")?.isEmpty == false { return m }
        return ModelStore.current()?.live == true ? m : nil
    }

    /// Launches the helper ahead of time so the model is loaded (and its Metal kernels
    /// compiled) before recording starts. Otherwise the first seconds get no captions.
    func prepare() {
        guard process == nil, let helper = Self.helperURL, let model = Self.liveModel else { return }
        ready = false
        stdoutBuffer = Data()

        let p = Process()
        p.executableURL = helper
        p.arguments = [model.path]
        // Parakeet Unified defaults to ~2 s of buffering per update; 160 ms chunks with
        // 160 ms lookahead give ~0.3 s captions at the same accuracy (other models ignore it).
        var env = ProcessInfo.processInfo.environment
        env["YAPSKETCH_ASR_CONTEXT"] = UserDefaults.standard.string(forKey: "liveContext") ?? "-1,160,160"
        // ggml's Metal residency sets come with a thread that wakes every 5 ms for as long as the
        // helper lives, and the helper idles for hours. Transcription is just as fast without them.
        env["GGML_METAL_NO_RESIDENCY"] = "1"
        p.environment = env
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                return
            }
            // ggml is chatty; keep only lines that look like problems.
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
            where line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("fail")
                || line.localizedCaseInsensitiveContains("rejected")
            {
                Log.info("asr helper: \(line.prefix(300))")
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.process === proc {
                    if self.active && !self.ready { self.onUnavailable?("Live transcription helper exited (\(proc.terminationStatus))") }
                    self.process = nil
                    self.stdin = nil
                }
                self.exited?.resume()
                self.exited = nil
            }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            lastUsed = Date()
            startIdleWatcher()
        } catch {
            Log.info("live captions: helper failed to start: \(error)")
        }
    }

    /// Another model was chosen: the loaded one goes (unless recording), the new one loads.
    func reload() {
        guard !active else { return }
        process?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.prepare() }
    }

    private func startIdleWatcher() {
        guard idleTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.unloadIfIdle() }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func unloadIfIdle() {
        let minutes = Self.unloadAfterMinutes
        guard minutes > 0, !active, let process,
            Date().timeIntervalSince(lastUsed) > Double(minutes) * 60
        else { return }
        Log.info("live captions: model idle for \(minutes) min, unloading")
        process.terminate()
    }

    func start(clock: @escaping () -> Double) {
        self.clock = clock
        audioStart = nil
        if process == nil { prepare() }
        guard process != nil else {
            onUnavailable?("Live transcription helper or model not found")
            return
        }
        active = true
        Log.info("live captions: \(engineName), model \(ready ? "already loaded" : "loading")")
    }

    /// Called on the capture audio queue.
    func append(_ sb: CMSampleBuffer) {
        guard active, let stdin, let pcm = convert(sb) else { return }
        if audioStart == nil { audioStart = clock?() ?? 0 }
        // Writes block until the helper has loaded its model and starts reading;
        // the queue absorbs that, and timestamps stay correct (they count samples).
        writeQueue.async {
            do { try stdin.write(contentsOf: pcm) } catch {}
        }
    }

    /// 16 kHz mono samples (dictation).
    func append(samples: [Float]) {
        guard active, let stdin, !samples.isEmpty else { return }
        if audioStart == nil { audioStart = clock?() ?? 0 }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        writeQueue.async {
            do { try stdin.write(contentsOf: data) } catch {}
        }
    }

    func finish() async {
        defer {
            // Warm up a fresh helper for the next recording.
            DispatchQueue.main.async { self.prepare() }
        }
        lastUsed = Date()
        guard let process, active else { return }
        active = false
        let handle = stdin
        stdin = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                guard process.isRunning else {
                    cont.resume()
                    return
                }
                self.exited = cont
                // EOF tells the helper to finalize and report the last sentence.
                self.writeQueue.async { try? handle?.close() }
                // Generous: the first launch compiles Metal kernels, and the helper may
                // still be draining buffered audio.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if process.isRunning { process.terminate() }
                }
            }
        }
        self.process = nil
    }

    // MARK: Audio

    private func convert(_ sb: CMSampleBuffer) -> Data? {
        guard let desc = sb.formatDescription, var asbd = desc.audioStreamBasicDescription,
            let inFormat = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr
        else { return nil }

        if converter == nil || converterInput != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converterInput = inFormat
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * 16_000 / inFormat.sampleRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, outBuf.frameLength > 0, let ch = outBuf.floatChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(outBuf.frameLength) * MemoryLayout<Float>.size)
    }

    // MARK: Helper output

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }
            DispatchQueue.main.async { self.handle(type, obj) }
        }
    }

    private func handle(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "ready":
            ready = true
            Log.info("live captions: model loaded")
        case "partial":
            if let text = obj["text"] as? String, !text.isEmpty { onPartial?(text) }
        case "segment":
            guard let text = obj["text"] as? String,
                let s = (obj["start_ms"] as? NSNumber)?.doubleValue,
                let e = (obj["end_ms"] as? NSNumber)?.doubleValue
            else { return }
            let base = audioStart ?? 0
            onSegment?(TranscriptSegment(start: base + s / 1000, end: base + e / 1000, text: text))
        case "error":
            let msg = obj["message"] as? String ?? "unknown error"
            Log.info("live captions: \(msg)")
            if !ready { onUnavailable?(msg) }
        default:
            break
        }
    }
}
