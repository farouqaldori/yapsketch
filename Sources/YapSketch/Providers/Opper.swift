import Foundation

/// Opper (https://opper.ai): sign in with the device flow, pay from the Opper wallet. Jev,
/// cloud speech models and a chat model for tidying up dictation.
struct Opper: Provider {
    let id = "opper"
    let name = "Opper"
    let offers = "Jev and cloud speech models"

    private static let api = "https://api.opper.ai"

    /// The OAuth app's client ID (a public client): `OpperClientID` in Info.plist, or `OPPER_CLIENT_ID`.
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

    var jev: JevEndpoint? {
        JevEndpoint(url: URL(string: Self.api + "/v3/compat/v1/systemone")!, model: "typesafe/jev-1.14.0", images: .multipart)
    }

    var chat: ChatEndpoint? { ChatEndpoint(url: URL(string: Self.api + "/v3/compat/chat/completions")!, model: "anthropic/claude-haiku-5-5") }

    var speech: [SpeechOffer] {
        [
            SpeechOffer(model: "elevenlabs/scribe_v2", name: "ElevenLabs Scribe v2", detail: "90+ languages · most accurate"),
            SpeechOffer(model: "gemini/gemini-3.5-transcribe", name: "Gemini 3.5 Transcribe", detail: "85+ languages"),
            SpeechOffer(model: "slng:us/deepgram/nova:3-en", name: "Deepgram Nova-3", detail: "English"),
            SpeechOffer(model: "mistral/voxtral-mini-2602", name: "Voxtral Mini", detail: "13 languages · EU-hosted"),
            SpeechOffer(model: "groq/whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", detail: "99 languages · fastest"),
        ]
    }

    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String) async -> [TranscriptSegment]? {
        let body: [String: Any] = ["model": model, "audio": "data:\(format.mime);base64,\(audio.base64EncodedString())"]
        guard let obj = await ProviderHTTP.post(self, URL(string: Self.api + "/v3/audio/transcriptions")!, key: key, json: body, timeout: 180)
        else { return nil }
        return CloudTranscript.segments(from: obj)
    }
}
