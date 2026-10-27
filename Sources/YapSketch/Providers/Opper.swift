import Foundation

struct Opper: Provider {
    let id = "opper"
    let name = "Opper"
    let offers = "Cloud speech models"

    private static let api = "https://api.opper.ai"

    /// A public client ID, not a secret.
    private static var clientID: String? {
        let id = ProcessInfo.processInfo.environment["OPPER_CLIENT_ID"] ?? (Bundle.main.object(forInfoDictionaryKey: "OpperClientID") as? String)
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    var connect: Connect {
        let flow = DeviceFlow(
            name: name, start: URL(string: Self.api + "/oauth/device")!, token: URL(string: Self.api + "/oauth/device/token")!,
            clientID: Self.clientID)
        return .browser { show in try await flow.run(show: show) }
    }

    var billing: Billing? {
        Billing(label: "Wallet", url: URL(string: "https://platform.opper.ai/wallet")!, empty: "Wallet is empty", topUp: "Top Up")
    }

    var speech: [ModelOffer] {
        [
            ModelOffer(model: "elevenlabs/scribe_v2", name: "ElevenLabs Scribe v2", detail: "90+ languages · most accurate"),
            ModelOffer(model: "gemini/gemini-3.5-transcribe", name: "Gemini 3.5 Transcribe", detail: "85+ languages"),
            ModelOffer(model: "slng:us/deepgram/nova:3-en", name: "Deepgram Nova-3", detail: "English"),
            ModelOffer(model: "mistral/voxtral-mini-2602", name: "Voxtral Mini", detail: "13 languages · EU-hosted"),
            ModelOffer(model: "groq/whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", detail: "99 languages · fastest"),
        ]
    }

    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String, words: [String]) async -> [TranscriptSegment]? {
        let body: [String: Any] = ["model": model, "audio": "data:\(format.mime);base64,\(audio.base64EncodedString())"]
        var hints: [String: Any] = [:]
        // ElevenLabs takes them as key terms, not a prompt.
        if model.hasPrefix("elevenlabs/") {
            if !words.isEmpty { hints["parameters"] = ["keyterms": Array(words.prefix(100))] }
        } else if let prompt = WordHints.prompt(words) {
            hints["prompt"] = prompt
        }
        let url = URL(string: Self.api + "/v3/audio/transcriptions")!
        return await WordHints.send(self, model: model, url: url, key: key, body: body, hints: hints).obj.map(CloudTranscript.segments(from:))
    }
}
