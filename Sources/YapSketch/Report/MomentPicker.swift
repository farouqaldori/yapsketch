import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Chooses the frame that best shows each narrated point the user didn't draw or point on.
struct MomentPicker {
    struct Candidate {
        let t: Double
        /// Relative to the session folder.
        let path: String
    }

    struct Point {
        let key: Int
        let said: String
        let candidates: [Candidate]
    }

    let session: Session
    let words: [TranscriptSegment]

    /// The chosen candidate's index by point key, or nil if Jev isn't available. Each point is
    /// its own request, all sent at once (Jev answers a few questions faster than many).
    func pick(_ points: [Point]) async -> [Int: Int]? {
        guard let key = Jev.apiKey() else { return nil }
        let results = await withTaskGroup(of: [Int: Int]?.self) { group in
            for p in points where p.candidates.count > 1 { group.addTask { await ask(p, key: key) } }
            var all: [[Int: Int]?] = []
            for await r in group { all.append(r) }
            return all
        }
        // The answers that came back count; a point whose request failed keeps its usual picture.
        let answered = results.compactMap { $0 }
        guard !answered.isEmpty || results.isEmpty else { return nil }
        return answered.reduce(into: [:]) { $0.merge($1) { a, _ in a } }
    }

    private func ask(_ p: Point, key: String) async -> [Int: Int]? {
        let width = Int(min(1400, max(640, (24_000 * 350 * 1.54 / Double(p.candidates.count)).squareRoot())))
        var assets: [String: [String: String]] = [:]
        var parts: [(String, Data)] = []
        var frames: [String: Any] = [:]
        var criteria: [String: Any] = [:]
        for (i, c) in p.candidates.enumerated() {
            guard let data = Self.jpeg(session.dir.appendingPathComponent(c.path), maxPixel: width) else { continue }
            let ref = UUID().uuidString.lowercased()
            let part = "img\(parts.count + 1)"
            assets[ref] = ["type": "image", "part": part]
            parts.append((part, data))
            frames["m\(i)"] = ref
            let spoken = saying(around: c.t)
            criteria["m\(i)"] = "`points.p\(p.key).frames.m\(i)`: the screen at \(Fmt.clock(c.t))\(spoken.isEmpty ? "" : ", while the user said \"\(spoken)\"")."
        }
        guard criteria.count > 1 else { return [:] }
        let body: [String: Any] = [
            "model": Jev.model, "state": ["points": ["p\(p.key)": ["said": p.said, "frames": frames]]], "assets": assets,
            "questions": [
                "pick_\(p.key)": [
                    "type": "choice",
                    "instructions":
                        "`points.p\(p.key).said` is one point a user made while narrating a screen recording for a developer, and the frames are the screen at moments during it. Which one best shows the issue or change the user is pointing out (what is wrong, or what they want different), rather than the steps they took to get there?",
                    "criteria": criteria,
                ] as [String: Any]
            ],
        ]
        guard let obj = await Jev.ask(body, images: parts, key: key), let answers = obj["answers"] as? [String: [String: Any]] else {
            Log.info("jev moments: request failed")
            return nil
        }
        guard let c = answers["pick_\(p.key)"]?["choice"] as? String, let i = Int(c.dropFirst()), i < p.candidates.count else { return [:] }
        Log.info("jev moments: point \(p.key), \(p.candidates.count) frames at \(width) px")
        return [p.key: i]
    }

    /// The words spoken within a couple of seconds of `t`.
    private func saying(around t: Double) -> String {
        words.filter { $0.end > t - 2 && $0.start < t + 1 }.map(\.text).joined(separator: " ")
    }

    /// Jev takes images 280–1568 px on each side: a wide picture is kept tall enough,
    /// whatever `maxPixel` asks.
    static func jpeg(_ url: URL, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var size = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, min(w, h) > 0
        {
            size = min(1568, max(size, Int((280.0 * Double(max(w, h)) / Double(min(w, h))).rounded(.up))), max(w, h))
        }
        guard
            let img = CGImageSourceCreateThumbnailAtIndex(
                src, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                ] as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
