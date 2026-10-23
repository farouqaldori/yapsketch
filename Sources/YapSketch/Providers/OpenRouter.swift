import Foundation

struct OpenRouter: Provider {
    let id = "openrouter"
    let name = "OpenRouter"
    let offers = "Cloud speech models"

    private static let api = "https://openrouter.ai/api"

    var connect: Connect {
        let flow = LoopbackPKCE(
            name: name, authorize: URL(string: "https://openrouter.ai/auth")!, exchange: URL(string: Self.api + "/v1/auth/keys")!,
            extraQuery: [URLQueryItem(name: "key_label", value: "YapSketch")])
        return .browser { show in try await flow.run(show: show) }
    }

    var billing: Billing? {
        Billing(label: "Credits", url: URL(string: "https://openrouter.ai/settings/credits")!, empty: "Out of credits", topUp: "Add Credits")
    }

    /// OpenRouter shows the app's name in the user's activity.
    var headers: [String: String] { ["X-Title": "YapSketch", "X-OpenRouter-Title": "YapSketch"] }

    var speech: [SpeechOffer] {
        [
            SpeechOffer(model: "elevenlabs/scribe-v2", name: "ElevenLabs Scribe v2", detail: "90+ languages · most accurate"),
            SpeechOffer(model: "google/gemini-3.5-transcribe", name: "Gemini 3.5 Transcribe", detail: "85+ languages"),
            SpeechOffer(model: "deepgram/nova-3", name: "Deepgram Nova-3", detail: "English"),
            SpeechOffer(model: "mistralai/voxtral-mini-transcribe", name: "Voxtral Mini", detail: "13 languages"),
            SpeechOffer(model: "openai/whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", detail: "99 languages · fastest"),
        ]
    }

    /// Asks for word timings; a model whose host can't give them (400) answers with text only.
    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String) async -> [TranscriptSegment]? {
        let url = URL(string: Self.api + "/v1/audio/transcriptions")!
        var body: [String: Any] = [
            "model": model, "input_audio": ["data": audio.base64EncodedString(), "format": format.rawValue],
            "response_format": "verbose_json", "timestamp_granularities": ["word", "segment"],
        ]
        for attempt in 0..<2 {
            guard let json = try? JSONSerialization.data(withJSONObject: body),
                let (data, status) = await ProviderHTTP.send(self, ProviderHTTP.request(self, url, key: key, timeout: 180), body: json)
            else { return nil }
            if status == 400, attempt == 0 {
                body["response_format"] = nil
                body["timestamp_granularities"] = nil
                continue
            }
            guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Log.info("openrouter: transcription HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
                if status == 200 { ProviderHTTP.record(.server(200), for: id) }
                return nil
            }
            Credentials.noteWorking(id)
            return CloudTranscript.segments(from: obj)
        }
        return nil
    }
}
