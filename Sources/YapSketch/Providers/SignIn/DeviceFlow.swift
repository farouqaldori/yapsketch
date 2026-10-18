import Foundation

/// OAuth's device flow (RFC 8628) as a public client, no secret in the app: get a code,
/// open the provider's page with it filled in, and poll until the user approves.
struct DeviceFlow: Sendable {
    let name: String
    /// Where codes are issued, and where they're traded for a key.
    let start: URL
    let token: URL
    let clientID: String?

    enum Failure: LocalizedError {
        case notSetUp(String), denied, expired, failed(String)
        var errorDescription: String? {
            switch self {
            case .notSetUp(let name): "Signing in with \(name) isn't set up in this build yet."
            case .denied: "Sign-in was declined."
            case .expired: "The sign-in code expired. Try again."
            case .failed(let s): s
            }
        }
    }

    func run(show: @escaping @Sendable (SignInPage) -> Void) async throws -> SignedIn {
        guard let clientID else { throw Failure.notSetUp(name) }
        let (issued, status) = try await form(start, ["client_id": clientID])
        guard status == 200, let device = issued["device_code"] as? String, let code = issued["user_code"] as? String,
            let page = URL(string: (issued["verification_uri_complete"] as? String) ?? (issued["verification_uri"] as? String) ?? "")
        else { throw Failure.failed(Self.detail(issued) ?? "\(name) didn't start the sign-in (HTTP \(status)).") }
        show(SignInPage(url: page, code: code))

        var interval = (issued["interval"] as? Double) ?? 5
        // Five minutes at most: long enough to sign in, not so long a closed tab waits for ages.
        let deadline = Date().addingTimeInterval(min((issued["expires_in"] as? Double) ?? 300, 300))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            // A dropped connection while waiting isn't the end of the sign-in: ask again.
            guard let (answer, status) = try? await form(token, ["device_code": device, "client_id": clientID]) else {
                try Task.checkCancellation()
                continue
            }
            if status == 200, let key = (answer["api_key"] ?? answer["access_token"]) as? String {
                let user = answer["user"] as? [String: Any]
                let name = (user?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (user?["email"] as? String)
                return SignedIn(key: key, user: name)
            }
            switch Self.detail(answer) ?? "" {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw Failure.denied
            case let other: throw Failure.failed(other.isEmpty ? "Sign-in failed (HTTP \(status))." : other)
            }
        }
        throw Failure.expired
    }

    private func form(_ url: URL, _ fields: [String: String]) async throws -> ([String: Any], Int) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        req.httpBody = Data(
            fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:], (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The error code, in RFC 8628's `error` or a `detail` field.
    private static func detail(_ obj: [String: Any]) -> String? {
        (obj["error"] as? String) ?? (obj["detail"] as? String) ?? ((obj["errors"] as? [[String: Any]])?.first?["detail"] as? String)
    }
}
