import AVFoundation
import Foundation

enum Audio16k {
    /// Decodes any audio file to 16 kHz mono, handing over converted buffers in order.
    static func decode(_ src: URL, _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        let input = try AVAudioFile(forReading: src)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input.processingFormat, to: outFormat),
            let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384)
        else {
            throw NSError(domain: "YapSketch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        }
        var eof = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8_192) else { break }
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if eof {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do { try input.read(into: inBuf) } catch { eof = true }
                if eof || inBuf.frameLength == 0 {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw err ?? NSError(domain: "YapSketch", code: 3) }
            if outBuf.frameLength > 0 { try sink(outBuf) }
            if status == .endOfStream { break }
        }
    }

    /// Raw 16 kHz mono float32 little-endian samples.
    static func floatData(_ src: URL) throws -> Data {
        var data = Data()
        try decode(src) { buf in
            guard let ch = buf.floatChannelData else { return }
            data.append(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        }
        return data
    }

    /// Groups word-level segments into sentences. Narration over a screen recording
    /// pauses mid-sentence a lot (while pointing or drawing), so pauses only split when
    /// long, and tiny leftover fragments are folded back into the sentence before them.
    static func sentences(from words: [TranscriptSegment]) -> [TranscriptSegment] {
        var groups: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        func flush() {
            if !current.isEmpty { groups.append(current) }
            current = []
        }
        for w in words {
            if let last = current.last, let first = current.first,
                w.start - last.end > 1.5 || w.end - first.start > 12
            {
                flush()
            }
            current.append(w)
            guard let c = w.text.last, let first = current.first else { continue }
            if ".?!".contains(c) || (w.end - first.start > 5 && ",;:".contains(c)) { flush() }
        }
        flush()

        // Fold fragments of one or two words into the previous sentence (or the next, at the start).
        var merged: [[TranscriptSegment]] = []
        for g in groups {
            if g.count <= 2, let prev = merged.last, let end = prev.last?.text.last, !".?!".contains(end) {
                merged[merged.count - 1] = prev + g
            } else {
                merged.append(g)
            }
        }
        if merged.count > 1, merged[0].count <= 2 {
            merged[1] = merged[0] + merged[1]
            merged.removeFirst()
        }
        return merged.compactMap { g in
            guard let first = g.first, let last = g.last else { return nil }
            return TranscriptSegment(start: first.start, end: last.end, text: g.map(\.text).joined(separator: " "), words: g)
        }
    }
}
