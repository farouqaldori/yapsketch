import AVFoundation
import Foundation

/// Where there's speech in 16 kHz mono audio, by loudness: enough to skip a silent dictation
/// and to leave long silences out of a recording before it's transcribed, which is where
/// speech models make words up. Not enough to judge words, so it errs on keeping audio.
enum SpeechCheck {
    /// 30 ms.
    private static let frame = 480
    /// About -48 dBFS: a quiet room stays under it, quiet speech goes over.
    private static let floor: Float = 0.004

    /// Why there's nothing to transcribe, or nil when there may be speech.
    static func nothingHeard(in samples: [Float]) -> String? {
        guard samples.contains(where: { $0 != 0 }) else { return "The microphone sent no sound" }
        // 150 ms over the line, in all.
        return levels(samples).filter { $0 > floor }.count >= 5 ? nil : "Nothing heard"
    }

    /// Audio with its long silences left out, and where each kept piece came from.
    struct Trimmed {
        struct Piece {
            let from: Double
            let to: Double
            let length: Double
        }
        let samples: [Float]
        let pieces: [Piece]

        /// A time in the trimmed audio, in the original.
        func original(_ t: Double) -> Double {
            guard let piece = pieces.last(where: { $0.to <= t }) ?? pieces.first else { return t }
            return piece.from + min(max(0, t - piece.to), piece.length)
        }

        /// Segments (and their words) timed in the trimmed audio, timed in the original.
        func original(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
            segments.map { s in
                var s = s
                s.start = original(s.start)
                s.end = max(s.start, original(s.end))
                s.words = s.words.map { $0.map { w in
                    var w = w
                    w.start = original(w.start)
                    w.end = max(w.start, original(w.end))
                    return w
                } }
                return s
            }
        }
    }

    /// The audio without silences of `gap` seconds or more, keeping `padding` around speech so
    /// no word is clipped. Nil when that would leave out too little to matter.
    static func trimmed(_ samples: [Float], gap: Double = 3, padding: Double = 1) -> Trimmed? {
        let lv = levels(samples)
        guard lv.count > 100 else { return nil }
        // Over the room's own noise (its quieter fifth), and never under the floor.
        let noise = lv.sorted()[lv.count / 5]
        let line = max(floor, noise * 2.5)
        let seconds = Double(frame) / 16_000
        let pad = Int(padding / seconds)
        var keep = [Bool](repeating: false, count: lv.count)
        for (i, l) in lv.enumerated() where l > line {
            for j in max(0, i - pad)...min(lv.count - 1, i + pad) { keep[j] = true }
        }
        // Runs of frames to keep, with shorter silences between them kept too.
        var runs: [Range<Int>] = []
        var i = 0
        while i < keep.count {
            guard keep[i] else {
                i += 1
                continue
            }
            var j = i
            while j < keep.count, keep[j] { j += 1 }
            if let last = runs.last, Double(i - last.upperBound) * seconds < gap {
                runs[runs.count - 1] = last.lowerBound..<j
            } else {
                runs.append(i..<j)
            }
            i = j
        }
        let kept = runs.reduce(0) { $0 + $1.count }
        let left = Double(lv.count - kept) * seconds
        guard !runs.isEmpty, left >= 10, Double(kept) < Double(lv.count) * 0.8 else { return nil }

        var out: [Float] = []
        out.reserveCapacity(kept * frame)
        var pieces: [Trimmed.Piece] = []
        // A short fade at each cut, so it doesn't click.
        let fade = 160
        for r in runs {
            let a = r.lowerBound * frame
            let b = min(samples.count, r.upperBound * frame)
            pieces.append(Trimmed.Piece(from: Double(a) / 16_000, to: Double(out.count) / 16_000, length: Double(b - a) / 16_000))
            var piece = Array(samples[a..<b])
            for k in 0..<min(fade, piece.count / 2) {
                let g = Float(k) / Float(fade)
                piece[k] *= g
                piece[piece.count - 1 - k] *= g
            }
            out += piece
        }
        return Trimmed(samples: out, pieces: pieces)
    }

    /// Loudness (RMS) of each 30 ms frame.
    private static func levels(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frame).map { start in
            let end = min(samples.count, start + frame)
            var sum: Float = 0
            for k in start..<end { sum += samples[k] * samples[k] }
            return (sum / Float(max(1, end - start))).squareRoot()
        }
    }
}
