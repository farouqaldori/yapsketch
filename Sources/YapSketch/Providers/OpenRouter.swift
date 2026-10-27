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

    var speech: [ModelOffer] {
        [
            ModelOffer(model: "elevenlabs/scribe-v2", name: "ElevenLabs Scribe v2", detail: "90+ languages · most accurate"),
            ModelOffer(model: "google/gemini-3.5-transcribe", name: "Gemini 3.5 Transcribe", detail: "85+ languages"),
            ModelOffer(model: "deepgram/nova-3", name: "Deepgram Nova-3", detail: "English"),
            ModelOffer(model: "mistralai/voxtral-mini-transcribe", name: "Voxtral Mini", detail: "13 languages"),
            ModelOffer(model: "openai/whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", detail: "99 languages · fastest"),
        ]
    }

    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String, words: [String]) async -> [TranscriptSegment]? {
        let url = URL(string: Self.api + "/v1/audio/transcriptions")!
        let hints: [String: Any] = WordHints.prompt(words).map { ["prompt": $0] } ?? [:]
        var body: [String: Any] = [
            "model": model, "input_audio": ["data": audio.base64EncodedString(), "format": format.rawValue],
            "response_format": "verbose_json", "timestamp_granularities": ["word", "segment"],
        ]
        var answer = await WordHints.send(self, model: model, url: url, key: key, body: body, hints: hints)
        if answer.status == 400 {
            body["response_format"] = nil
            body["timestamp_granularities"] = nil
            answer = await WordHints.send(self, model: model, url: url, key: key, body: body, hints: hints)
        }
        return answer.obj.map(CloudTranscript.segments(from:))
    }
}
