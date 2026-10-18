import CryptoKit
import Foundation
import Network

/// OAuth PKCE with the browser coming back to a one-off loopback port. No client
/// registration and no secret in the app.
struct LoopbackPKCE: Sendable {
    let name: String
    /// The provider's consent page; `callback_url`, the challenge and `state` are added.
    let authorize: URL
    let exchange: URL
    var extraQuery: [URLQueryItem] = []

    enum Failure: LocalizedError {
        case denied, timedOut, failed(String)
        var errorDescription: String? {
            switch self {
            case .denied: "Connecting was declined."
            case .timedOut: "Connecting timed out. Try again."
            case .failed(let s): s
            }
        }
    }

    func run(show: @escaping @Sendable (SignInPage) -> Void) async throws -> SignedIn {
        let verifier = Self.base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let callback = try await Callback.start()
        defer { callback.stop() }
        var parts = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "callback_url", value: "http://localhost:\(callback.port)/callback"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ] + extraQuery
        show(SignInPage(url: parts.url!))

        let query = try await callback.wait(timeout: 180)
        if query["error"] != nil { throw Failure.denied }
        guard let code = query["code"], query["state"] == state else { throw Failure.failed("\(name) didn't finish connecting. Try again.") }

        var req = URLRequest(url: exchange, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200, let key = (obj["key"] ?? obj["access_token"]) as? String else {
            throw Failure.failed("\(name) didn't return a key. Try again.")
        }
        return SignedIn(key: key)
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A one-request web server on a free loopback port, for the browser to bring the code back to.
    final class Callback: @unchecked Sendable {
        let port: UInt16
        private let listener: NWListener
        private let queue = DispatchQueue(label: "yapsketch.signin.callback")
        private var continuation: CheckedContinuation<[String: String], Error>?
        private var result: Result<[String: String], Error>?

        private init(listener: NWListener, port: UInt16) {
            self.listener = listener
            self.port = port
        }

        static func start() async throws -> Callback {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                // State updates arrive on the listener's own queue, one at a time.
                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                listener.stateUpdateHandler = { state in
                    guard !once.done else { return }
                    switch state {
                    case .ready:
                        once.done = true
                        cont.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let e):
                        once.done = true
                        cont.resume(throwing: e)
                    default: break
                    }
                }
                listener.newConnectionHandler = { $0.cancel() }
                listener.start(queue: DispatchQueue(label: "yapsketch.signin.listen"))
            }
            let callback = Callback(listener: listener, port: port)
            listener.newConnectionHandler = { [weak callback] c in callback?.handle(c) }
            return callback
        }

        func wait(timeout: TimeInterval) async throws -> [String: String] {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    queue.async {
                        if let r = self.result {
                            cont.resume(with: r)
                            return
                        }
                        self.continuation = cont
                        self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(Failure.timedOut)) }
                    }
                }
            } onCancel: {
                self.queue.async { self.finish(.failure(CancellationError())) }
            }
        }

        func stop() { listener.cancel() }

        private func finish(_ r: Result<[String: String], Error>) {
            guard result == nil else { return }
            result = r
            continuation?.resume(with: r)
            continuation = nil
        }

        private func handle(_ c: NWConnection) {
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { data, _, _, _ in
                // "GET /callback?code=…&state=… HTTP/1.1"
                let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                guard target.hasPrefix("/callback"), let parts = URLComponents(string: "http://localhost" + target) else {
                    c.send(
                        content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in c.cancel() })
                    return
                }
                var query: [String: String] = [:]
                for item in parts.queryItems ?? [] { query[item.name] = item.value ?? "" }
                let page = """
                    <!doctype html><meta charset="utf-8"><title>YapSketch</title>
                    <body style="font:15px -apple-system,system-ui;display:grid;place-items:center;height:90vh;color:#444">
                    <p>\(query["error"] == nil ? "Connected to YapSketch. You can close this tab." : "Not connected. You can close this tab.")</p>
                    """
                let body = Data(page.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
                self.finish(.success(query))
            }
        }
    }
}
