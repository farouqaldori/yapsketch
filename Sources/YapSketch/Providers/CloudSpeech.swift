import Foundation

/// `id` is how the `modelID` setting names it.
struct CloudModel: Identifiable {
    let providerID: String
    let model: String
    let name: String
    let detail: String
    var id: String { "\(providerID):\(model)" }
    var provider: (any Provider)? { Providers.named(providerID) }
    var providerName: String { provider?.name ?? providerID }
}

enum CloudSpeech {
    static var all: [CloudModel] {
        Providers.all.flatMap { p in p.speech.map { CloudModel(providerID: p.id, model: $0.model, name: $0.name, detail: $0.detail) } }
    }

    static func available() -> [CloudModel] { all.filter { $0.provider?.isConnected == true } }

    static func selected() -> CloudModel? {
        guard let id = UserDefaults.standard.string(forKey: "modelID") else { return nil }
        return available().first { $0.id == id }
    }

    /// nil if the audio is too big to send, or the provider failed or took longer than `deadline` seconds.
    static func transcribe(audio: URL, model: CloudModel, deadline: Double = 120) async -> [TranscriptSegment]? {
        guard let provider = model.provider, let key = provider.key,
            let bytes = try? Data(contentsOf: audio), bytes.count < 24 << 20
        else { return nil }
        let started = CFAbsoluteTimeGetCurrent()
        let since = Date()
        let format = AudioFormat(audio)
        let words = TextCleanup.customWords
        let segments = await Deadline.run(deadline) { await provider.transcribe(bytes, format: format, model: model.model, key: key, words: words) }
        if segments == nil, ProviderHTTP.trouble(for: provider.id, since: since) == nil {
            Log.info("\(provider.id): no transcript within \(Int(deadline))s")
            ProviderHTTP.record(.offline, for: provider.id)
        }
        if segments != nil {
            Log.info(String(format: "%@: transcribed with %@ in %.1fs", provider.id, model.model, CFAbsoluteTimeGetCurrent() - started))
        }
        return segments
    }

    /// After disconnecting a provider, switches back to the local model if it hosted the chosen one.
    @MainActor
    static func forget(_ provider: any Provider) {
        guard let id = UserDefaults.standard.string(forKey: "modelID"), all.contains(where: { $0.id == id && $0.providerID == provider.id })
        else { return }
        ModelStore.shared.selectedID = ModelStore.current()?.id ?? "parakeet-unified"
        NotificationCenter.default.post(name: .yapSketchModelChanged, object: nil)
    }
}

/// Custom words sent along with the audio, so the model spells them right. A model that
/// refuses them (400) is asked again without, and isn't sent them again.
enum WordHints {
    /// The words as a short prompt, the way speech models take one.
    static func prompt(_ words: [String]) -> String? {
        var kept: [String] = []
        var length = 0
        for w in words where length + w.count < 600 {
            kept.append(w)
            length += w.count + 2
        }
        return kept.isEmpty ? nil : kept.joined(separator: ", ") + "."
    }

    /// The answer, if it worked, and the HTTP status (0 when unreachable).
    static func send(
        _ provider: any Provider, model: String, url: URL, key: String, body: [String: Any], hints: [String: Any]
    ) async -> (obj: [String: Any]?, status: Int) {
        let refused = "refusesWordHints.\(provider.id):\(model)"
        let withHints = !hints.isEmpty && !UserDefaults.standard.bool(forKey: refused)
        let first = await post(provider, url, key, withHints ? body.merging(hints) { $1 } : body)
        guard withHints, first.status == 400 else { return first }
        let second = await post(provider, url, key, body)
        if second.obj != nil {
            UserDefaults.standard.set(true, forKey: refused)
            Log.info("\(provider.id): \(model) doesn't take custom words")
        }
        return second
    }

    private static func post(_ provider: any Provider, _ url: URL, _ key: String, _ body: [String: Any]) async -> (
        obj: [String: Any]?, status: Int
    ) {
        guard let json = try? JSONSerialization.data(withJSONObject: body),
            let (data, status) = await ProviderHTTP.send(provider, ProviderHTTP.request(provider, url, key: key, timeout: 180), body: json)
        else { return (nil, 0) }
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.info("\(provider.id): transcription HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
            if status == 200 { ProviderHTTP.record(.server(200), for: provider.id) }
            return (nil, status)
        }
        Credentials.noteWorking(provider.id)
        return (obj, status)
    }
}

/// Words are spread evenly through a segment when the model gives none.
enum CloudTranscript {
    static func segments(from obj: [String: Any]) -> [TranscriptSegment] {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        let words: [TranscriptSegment] = ((obj["words"] as? [[String: Any]]) ?? []).compactMap { w in
            guard let t = ((w["word"] ?? w["text"]) as? String)?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
                let s = num(w["start"]), let e = num(w["end"])
            else { return nil }
            return TranscriptSegment(start: s, end: e, text: t)
        }
        var segs: [TranscriptSegment] = ((obj["segments"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let t = (s["text"] as? String)?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
                let a = num(s["start"]), let b = num(s["end"])
            else { return nil }
            return TranscriptSegment(start: a, end: b, text: t)
        }
        if segs.isEmpty, !words.isEmpty {
            var current: [TranscriptSegment] = []
            for w in words {
                current.append(w)
                if w.text.last.map({ ".?!".contains($0) }) ?? false {
                    segs.append(TranscriptSegment(start: current[0].start, end: w.end, text: current.map(\.text).joined(separator: " ")))
                    current = []
                }
            }
            if !current.isEmpty {
                segs.append(
                    TranscriptSegment(start: current[0].start, end: current.last!.end, text: current.map(\.text).joined(separator: " ")))
            }
        }
        if segs.isEmpty, let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            segs = [TranscriptSegment(start: 0, end: num(obj["duration"]) ?? Double(text.split(separator: " ").count) * 0.4, text: text)]
        }
        for i in segs.indices {
            let inside = words.filter { $0.start >= segs[i].start - 0.05 && $0.end <= segs[i].end + 0.05 }
            if !inside.isEmpty {
                segs[i].words = inside
            } else {
                let parts = segs[i].text.split(separator: " ").map(String.init)
                let step = (segs[i].end - segs[i].start) / Double(max(1, parts.count))
                segs[i].words = parts.enumerated().map { k, p in
                    TranscriptSegment(start: segs[i].start + Double(k) * step, end: segs[i].start + Double(k + 1) * step, text: p)
                }
            }
        }
        return segs
    }
}
