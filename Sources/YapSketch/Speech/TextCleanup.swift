import Foundation

/// What happens to a transcript before it's used, for dictation and recordings alike: your
/// own words put right (names, jargon a model mishears), and "um"s taken out. Local and
/// instant; the optional AI cleanup (dictation only) is separate.
enum TextCleanup {
    /// Your words, one per line (Settings › Dictation).
    static var customWords: [String] {
        (UserDefaults.standard.string(forKey: "customWords") ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var removeFillers: Bool { UserDefaults.standard.object(forKey: "removeFillers") as? Bool ?? true }

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "uhh", "erm", "er", "ah", "hmm", "mm", "mhm"]

    /// A whole text: fillers out, custom words in, spacing and the first letter tidied.
    static func apply(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map {
            TranscriptSegment(start: 0, end: 0, text: String($0))
        }
        if removeFillers { tokens = dropFillers(tokens) }
        return correct(tokens).map(\.text).joined(separator: " ")
    }

    /// A recording's transcript: the same, word by word, keeping each word's timing.
    static func apply(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let words = customWords
        guard removeFillers || !words.isEmpty else { return segments }
        return segments.compactMap { s in
            var s = s
            if var ws = s.words {
                if removeFillers { ws = dropFillers(ws) }
                ws = correct(ws)
                s.words = ws
                s.text = ws.map(\.text).joined(separator: " ")
            } else {
                s.text = apply(s.text)
            }
            return s.text.isEmpty ? nil : s
        }
    }

    /// The words without fillers, the punctuation mended: "these, uh, are" → "these are", and
    /// "Um, so it" → "So it" (a sentence that started with a filler starts with the next word).
    static func dropFillers(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var capitalize = false
        for w in words {
            if isFiller(w.text) {
                let startsSentence = out.last.map { $0.text.last.map { ".?!".contains($0) } ?? false } ?? true
                if startsSentence || w.text.first?.isUppercase == true { capitalize = true }
                if w.text.hasSuffix(","), out.last?.text.hasSuffix(",") == true { out[out.count - 1].text.removeLast() }
                if let end = w.text.last, ".?!".contains(end), let last = out.last?.text.last, !last.isPunctuation {
                    out[out.count - 1].text.append(end)
                    capitalize = true
                }
                continue
            }
            var w = w
            if capitalize, let first = w.text.first, first.isLowercase { w.text = first.uppercased() + w.text.dropFirst() }
            capitalize = false
            out.append(w)
        }
        return out
    }

    /// "Um," → filler (the punctuation around it doesn't matter).
    static func isFiller(_ token: String) -> Bool {
        fillers.contains(token.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    /// Each custom word (or phrase) replaces runs of words that sound and look like it:
    /// close in spelling (edit distance within 18% of its length, as Handy does) or, when
    /// they sound the same (Soundex), within 34%. A run becomes one word spanning its time.
    static func correct(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        let custom = customWords
        guard !custom.isEmpty, !words.isEmpty else { return words }
        var out = words
        for phrase in custom {
            let target = normalize(phrase).replacingOccurrences(of: " ", with: "")
            guard target.count >= 3 else { continue }
            let n = phrase.split(separator: " ").count
            // Models often split a word ("open router"), so one word more is tried first.
            for size in [n + 1, n] {
                var i = 0
                while i + size <= out.count {
                    let run = out[i..<(i + size)]
                    let joined = normalize(run.map(\.text).joined()).replacingOccurrences(of: " ", with: "")
                    let alreadyThere = run.contains { normalize($0.text) == normalize(phrase) }
                    // A split word must be spelled close; the sounds-alike rule is for same-size runs.
                    if !alreadyThere, close(joined, target, soundsAlike: size == n), let first = run.first, let last = run.last {
                        // Keep the punctuation around the run.
                        let lead = String(first.text.prefix { $0.isPunctuation })
                        let trail = String(last.text.reversed().prefix { $0.isPunctuation }.reversed())
                        let merged = TranscriptSegment(start: first.start, end: last.end, text: lead + phrase + trail)
                        out.replaceSubrange(i..<(i + size), with: [merged])
                    }
                    i += 1
                }
            }
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }

    private static func close(_ a: String, _ b: String, soundsAlike: Bool = true) -> Bool {
        guard !a.isEmpty, abs(a.count - b.count) <= max(2, b.count / 3) else { return false }
        let d = Double(distance(a, b)) / Double(max(a.count, b.count))
        return d <= 0.18 || (soundsAlike && d <= 0.34 && soundex(a) == soundex(b))
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }

    private static func soundex(_ s: String) -> String {
        let letters = Array(s.uppercased().filter(\.isLetter))
        guard let first = letters.first else { return "" }
        func code(_ c: Character) -> Character? {
            switch c {
            case "B", "F", "P", "V": "1"
            case "C", "G", "J", "K", "Q", "S", "X", "Z": "2"
            case "D", "T": "3"
            case "L": "4"
            case "M", "N": "5"
            case "R": "6"
            default: nil
            }
        }
        var out = [first]
        var last = code(first)
        for c in letters.dropFirst() {
            let k = code(c)
            if let k, k != last { out.append(k) }
            if c != "H" && c != "W" { last = k }
            if out.count == 4 { break }
        }
        return String(out + Array(repeating: "0", count: 4 - out.count))
    }

    // MARK: AI cleanup (dictation)

    /// The connected provider chosen to tidy dictations (one with a chat model), or nil.
    static var aiProvider: (any Provider)? {
        Providers.named(UserDefaults.standard.string(forKey: "dictationCleanup")).flatMap { $0.chat != nil && $0.isConnected ? $0 : nil }
    }

    static let aiPrompt = """
        You clean up dictated text. Fix punctuation, capitalization and obvious speech-recognition \
        mistakes; remove false starts and repeated words. Keep the speaker's words, meaning and \
        tone; don't add, summarize or answer anything. Reply with only the cleaned text.
        """

    /// The text tidied by the provider's chat model; nil if it fails.
    static func aiClean(_ text: String) async -> String? {
        guard let provider = aiProvider, let chat = provider.chat, let key = provider.key, !text.isEmpty else { return nil }
        let body: [String: Any] = [
            "model": chat.model, "temperature": 0,
            "messages": [["role": "system", "content": aiPrompt], ["role": "user", "content": text]],
        ]
        guard let obj = await ProviderHTTP.post(provider, chat.url, key: key, json: body, timeout: 20),
            let choice = (obj["choices"] as? [[String: Any]])?.first,
            let content = (choice["message"] as? [String: Any])?["content"] as? String
        else { return nil }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
