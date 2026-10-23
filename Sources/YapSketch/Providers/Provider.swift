import Foundation

/// To add a provider, write a type that conforms and list it in `Providers.all`.
protocol Provider: Sendable {
    /// Stable: the Keychain item `com.yapsketch.<id>`, `<ID>_API_KEY`, saved choices, and the
    /// logo `Resources/Providers/<id>.png`.
    var id: String { get }
    var name: String { get }
    /// Shown under its name.
    var offers: String { get }
    var connect: Connect { get }
    var billing: Billing? { get }
    var headers: [String: String] { get }

    var speech: [SpeechOffer] { get }
    /// Use `ProviderHTTP` so problems are noted.
    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String) async -> [TranscriptSegment]?
}

extension Provider {
    var billing: Billing? { nil }
    var headers: [String: String] { [:] }
    var speech: [SpeechOffer] { [] }
    func transcribe(_ audio: Data, format: AudioFormat, model: String, key: String) async -> [TranscriptSegment]? { nil }

    var key: String? { Credentials.key(for: id) }
    var isConnected: Bool { key != nil }
}

enum Connect: Sendable {
    /// `show` reports the page (and any code to confirm) while waiting.
    case browser(@Sendable (_ show: @escaping @Sendable (SignInPage) -> Void) async throws -> SignedIn)
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
    let label: String
    let url: URL
    /// What a 402 means here, and the button for it.
    let empty: String
    let topUp: String
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
    static let all: [any Provider] = [Opper(), OpenRouter()]

    static func named(_ id: String?) -> (any Provider)? { all.first { $0.id == id } }
    static var connected: [any Provider] { all.filter(\.isConnected) }
}
