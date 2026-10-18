import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit

/// Records a display (including YapSketch's own overlay, so drawings, captions
/// and the clock are burned in) plus the microphone via ScreenCaptureKit.
// @unchecked: its mutable state is only changed on the main queue (see resumeFinish).
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    /// Called on the audio queue for every microphone buffer.
    var onMicBuffer: ((CMSampleBuffer) -> Void)?
    /// Every screen frame captured (on the capture queue; keep it quick).
    var onScreenFrame: ((CVPixelBuffer) -> Void)?
    /// Called once the recording file has started receiving frames.
    var onStarted: (() -> Void)?
    var onError: ((Error) -> Void)?
    /// Capture ended without us asking (user hit "Stop Sharing", display went away…).
    var onStoppedUnexpectedly: (() -> Void)?
    private var stopping = false

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var micWriter: MicWriter?
    private let videoQueue = DispatchQueue(label: "yapsketch.video")
    private let audioQueue = DispatchQueue(label: "yapsketch.audio")
    private var finishContinuation: CheckedContinuation<Void, Never>?

    /// `excludingWindows`: YapSketch windows to leave out of the capture (the mini player).
    func start(
        display info: DisplayInfo, videoURL: URL, micURL: URL, systemAudio: Bool,
        excludingWindows excluded: [CGWindowID] = []
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == info.displayID }) ?? content.displays.first else {
            throw NSError(domain: "YapSketch", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available to record"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
        let config = SCStreamConfiguration()
        // Recording one window: crop the screen capture to it (rather than capturing the
        // window alone), so YapSketch's ink layer on top is still recorded.
        if info.captureOffset != .zero || info.size != info.screen.size {
            config.sourceRect = CGRect(origin: info.captureOffset, size: info.size)
        }
        config.width = Int(info.size.width * info.scale)
        config.height = Int(info.size.height * info.scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        if let mic = AVCaptureDevice.default(for: .audio) {
            config.microphoneCaptureDeviceID = mic.uniqueID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // A screen output is required for SCK to deliver frames to the recording output
        // without log spam; the same frames also feed the live frame log.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = videoURL
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = .h264
        let rec = SCRecordingOutput(configuration: recConfig, delegate: self)
        try stream.addRecordingOutput(rec)

        micWriter = MicWriter(url: micURL)
        self.stream = stream
        self.recordingOutput = rec
        try await stream.startCapture()
    }

    /// The frontmost app's main window, in global coordinates, if it's on `displayID`.
    static func frontWindowFrame(on displayID: CGDirectDisplayID) async -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return nil }
        let screen = CGDisplayBounds(displayID)
        var best: CGRect?
        for w in content.windows where w.owningApplication?.processID == pid && w.windowLayer == 0 {
            let r = w.frame.intersection(screen)
            guard !r.isNull, r.width > 200, r.height > 150 else { continue }
            if r.width * r.height > best.map({ $0.width * $0.height }) ?? 0 { best = r }
        }
        return best?.integral
    }

    /// Loudness of a mic buffer, 0…1 (float PCM, as ScreenCaptureKit delivers it).
    static func level(_ sb: CMSampleBuffer) -> Float {
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sb, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
            let data = list.mBuffers.mData
        else { return 0 }
        let n = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard n > 0 else { return 0 }
        let samples = data.bindMemory(to: Float.self, capacity: n)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(1e-6, (sum / Float(n)).squareRoot()))
        return max(0, min(1, (db + 50) / 40))
    }

    func stop() async {
        guard let stream else { return }
        stopping = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            stream.stopCapture { [weak self] error in if error != nil { self?.resumeFinish() } }
            // Don't hang forever if the delegate never fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.resumeFinish() }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            audioQueue.async { [micWriter] in
                micWriter?.finish { cont.resume() }
                if micWriter == nil { cont.resume() }
            }
        }
        self.stream = nil
        self.recordingOutput = nil
        self.micWriter = nil
    }

    private func resumeFinish() {
        DispatchQueue.main.async {
            self.finishContinuation?.resume()
            self.finishContinuation = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            if let handler = onScreenFrame, sampleBuffer.isValid, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                handler(pixels)
            }
            return
        }
        guard type == .microphone, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        micWriter?.append(sampleBuffer)
        onMicBuffer?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped: \(error.localizedDescription)")
        onError?(error)
        resumeFinish()
        if !stopping { DispatchQueue.main.async { self.onStoppedUnexpectedly?() } }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        onStarted?()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Log.info("recording output failed: \(error.localizedDescription)")
        onError?(error)
        resumeFinish()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resumeFinish()
    }
}

/// Writes the raw microphone track to its own file. Used for the Whisper pass
/// and as a safety net in case the video file ends up without audio.
// @unchecked: used only on the recorder's audio queue.
final class MicWriter: @unchecked Sendable {
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var failed = false

    init(url: URL) { self.url = url }

    func append(_ sb: CMSampleBuffer) {
        if writer == nil && !failed { setUp(with: sb) }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    private func setUp(with sb: CMSampleBuffer) {
        guard let fmt = sb.formatDescription,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
        else {
            failed = true
            return
        }
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let i = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: asbd.mSampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 96_000 * channels,
                ], sourceFormatHint: fmt)
            i.expectsMediaDataInRealTime = true
            w.add(i)
            w.startWriting()
            w.startSession(atSourceTime: sb.presentationTimeStamp)
            writer = w
            input = i
        } catch {
            NSLog("YapSketch: mic writer failed: \(error)")
            failed = true
        }
    }

    func finish(_ done: @escaping () -> Void) {
        guard let writer, writer.status == .writing else {
            done()
            return
        }
        input?.markAsFinished()
        writer.finishWriting { done() }
    }
}
