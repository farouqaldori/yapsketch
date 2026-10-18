import Foundation

/// JavaScript errors from Chrome, through the DevTools protocol. Needs Chrome started with
/// remote debugging on, e.g.
///   open -a "Google Chrome" --args --remote-debugging-port=9222 --user-data-dir=/tmp/yapsketch-chrome
final class ConsoleMonitor {
    /// Main queue.
    var onError: ((String) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var nextID = 1

    static let port = 9222

    /// Connects to the open tab whose address matches `url` (or the first page).
    func start(preferring url: String?) {
        let list = URL(string: "http://127.0.0.1:\(Self.port)/json")!
        var req = URLRequest(url: list, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return }
            let tabs = pages.filter { $0["type"] as? String == "page" }
            let tab = tabs.first { ($0["url"] as? String) == url } ?? tabs.first
            guard let ws = (tab?["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { return }
            Log.info("console: connected to \(tab?["url"] as? String ?? "?")")
            let socket = URLSession.shared.webSocketTask(with: ws)
            self.socket = socket
            socket.resume()
            self.send("Runtime.enable")
            self.send("Log.enable")
            self.receive()
        }.resume()
    }

    func stop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func send(_ method: String) {
        let msg = "{\"id\":\(nextID),\"method\":\"\(method)\"}"
        nextID += 1
        socket?.send(.string(msg)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            if case .success(.string(let text)) = result,
                let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let message = Self.error(in: obj)
            {
                DispatchQueue.main.async { self.onError?(message) }
            }
            if case .failure = result { return }
            self.receive()
        }
    }

    /// An uncaught exception, console.error, or browser-logged error, as one line.
    private static func error(in obj: [String: Any]) -> String? {
        guard let method = obj["method"] as? String, let params = obj["params"] as? [String: Any] else { return nil }
        switch method {
        case "Runtime.exceptionThrown":
            let d = params["exceptionDetails"] as? [String: Any]
            let ex = d?["exception"] as? [String: Any]
            return (ex?["description"] as? String ?? d?["text"] as? String).map { "Uncaught " + firstLine($0) }
        case "Runtime.consoleAPICalled":
            guard params["type"] as? String == "error", let args = params["args"] as? [[String: Any]] else { return nil }
            let parts = args.compactMap { $0["description"] as? String ?? ($0["value"]).map { "\($0)" } }
            return parts.isEmpty ? nil : "console.error: " + firstLine(parts.joined(separator: " "))
        case "Log.entryAdded":
            let entry = params["entry"] as? [String: Any]
            guard entry?["level"] as? String == "error", let text = entry?["text"] as? String else { return nil }
            let url = (entry?["url"] as? String).map { " (\($0))" } ?? ""
            return firstLine(text) + url
        default:
            return nil
        }
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
