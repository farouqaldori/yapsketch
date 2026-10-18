import Foundation

/// A service YapSketch can send work to. Settings, Jev, cloud speech and the AI tidy-up only
/// see this protocol: to add a provider, write a type that conforms and list it in
/// `Providers.all`. Everything it doesn't offer has a default.
protocol Provider: Sendable {
    /// Stable: the Keychain item `com.yapsketch.<id>`, `<ID>_API_KEY`, saved choices, and the
    /// logo `Resources/Providers/<id>.png`.
    var id: String { get }
    var name: String { get }
    /// What it adds, shown under its name.
    var offers: String { get }
    var connect: Connect { get }
    /// Where the account is managed, and how running out of funds reads.
    var billing: Billing? { get }
    /// Sent with every request (e.g. naming the app).
    var headers: [String: String] { get }

    var jev: JevEndpoint? { get }
    var speech: [SpeechOffer] { get }
    /// Its speech models' transcription of `audio`; use `ProviderHTTP` so problems are noted.
    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String) async -> [TranscriptSegment]?
    /// An OpenAI-compatible chat endpoint, for tidying up dictation.
    var chat: ChatEndpoint? { get }
}

extension Provider {
    var billing: Billing? { nil }
    var headers: [String: String] { [:] }
    var jev: JevEndpoint? { nil }
    var speech: [SpeechOffer] { [] }
    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String) async -> [TranscriptSegment]? { nil }
    var chat: ChatEndpoint? { nil }

    var key: String? { Credentials.key(for: id) }
    var isConnected: Bool { key != nil }
}

/// How an account is connected.
enum Connect: Sendable {
    /// Paste an API key: where to get one, and a check that one works.
    case apiKey(getOne: URL, check: @Sendable (String) async -> KeyCheck)
    /// Sign in in the browser. `show` reports the page (and any code to confirm) while waiting.
    case browser(@Sendable (_ show: @escaping @Sendable (SignInPage) -> Void) async throws -> SignedIn)
}

/// What trying a pasted key found.
enum KeyCheck: Sendable {
    case works, rejected, outOfFunds, unreachable

    /// What to tell the person, unless it simply works.
    func message(_ name: String) -> String? {
        switch self {
        case .works: nil
        case .rejected: "That key didn't work"
        case .outOfFunds: "The key works, but \(name) is out of credits"
        case .unreachable: "Couldn't reach \(name). Check your connection"
        }
    }
}

struct SignInPage: Sendable, Equatable {
    let url: URL
    var code: String?
}

struct SignedIn: Sendable {
    let key: String
    var user: String?
}

struct Billing: Sendable {
    /// "Wallet", "Credits".
    let label: String
    let url: URL
    /// What a 402 means here ("Wallet is empty"), and the button for it ("Top Up").
    let empty: String
    let topUp: String
}

struct JevEndpoint: Sendable {
    let url: URL
    let model: String
    /// How pictures travel: multipart parts (System One), or inline in the JSON (Decisions API).
    let images: Images
    enum Images: Sendable { case multipart, inline }
}

struct ChatEndpoint: Sendable {
    let url: URL
    let model: String

    /// "anthropic/claude-haiku-5-5" → "Claude Haiku 5.5".
    var modelName: String {
        let parts = (model.split(separator: "/").last ?? "").split(separator: "-")
        var words: [String] = []
        var version: [String] = []
        for p in parts {
            if p.first?.isNumber == true { version.append(String(p)) } else { words.append(p.prefix(1).uppercased() + p.dropFirst()) }
        }
        return (words + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }
}

struct SpeechOffer: Sendable {
    let model: String
    let name: String
    let detail: String
}

enum AudioFormat: String, Sendable {
    case wav, m4a
    var mime: String { self == .wav ? "audio/wav" : "audio/mp4" }
    init(_ url: URL) { self = url.pathExtension.lowercased() == "wav" ? .wav : .m4a }
}

enum Providers {
    static let all: [any Provider] = [TypeSafe(), Opper(), OpenRouter()]

    static func named(_ id: String?) -> (any Provider)? { all.first { $0.id == id } }
    static var connected: [any Provider] { all.filter(\.isConnected) }
}
