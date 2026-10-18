import AVFoundation
import Foundation

enum ParakeetOffline {
    struct Result {
        let segments: [TranscriptSegment]
        let model: String
    }

    static func transcribe(audio: URL) async -> Result? {
        guard let helper = ParakeetLive.helperURL, let model = ParakeetLive.findModel() else { return nil }
        let pcm: Data
        do { pcm = try Audio16k.floatData(audio) } catch {
            Log.info("parakeet: audio decode failed: \(error)")
            return nil
        }
        let output: Data? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = helper
                p.arguments = ["--offline", model.path]
                let inPipe = Pipe()
                let outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: nil)
                    return
                }
                // The helper reads all input before printing, so write everything, then read.
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: pcm)
                    try? inPipe.fileHandleForWriting.close()
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? data : nil)
            }
        }
        guard let output else {
            Log.info("parakeet: offline transcription failed")
            return nil
        }
        for line in output.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                obj["type"] as? String == "words", let items = obj["words"] as? [[String: Any]]
            else { continue }
            let words: [TranscriptSegment] = items.compactMap {
                guard let t0 = ($0["t0_ms"] as? NSNumber)?.doubleValue, let t1 = ($0["t1_ms"] as? NSNumber)?.doubleValue,
                    let text = $0["text"] as? String
                else { return nil }
                return TranscriptSegment(start: t0 / 1000, end: t1 / 1000, text: text)
            }
            return Result(segments: Audio16k.sentences(from: words), model: model.deletingPathExtension().lastPathComponent)
        }
        return nil
    }
}
