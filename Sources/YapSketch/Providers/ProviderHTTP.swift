import Foundation

/// What went wrong with a provider, in words a person can act on.
enum ProviderTrouble: Equatable, Sendable {
    case offline, outOfFunds, revoked, busy
    case server(Int)

    /// "Opper is out of credits", for a pill or a report's note.
    func sentence(_ name: String) -> String {
        switch self {
        case .offline: "Couldn't reach \(name)"
        case .outOfFunds: "\(name) is out of credits"
        case .revoked: "\(name) needs reconnecting"
        case .busy: "\(name) is busy"
        case .server(let status): "\(name) had a problem (\(status))"
        }
    }

    init?(status: Int) {
        switch status {
        case 401, 403: self = .revoked
        case 402: self = .outOfFunds
        case 429, 529: self = .busy
        case 500...: self = .server(status)
        default: return nil
        }
    }
}

/// Work that gives up after `seconds` (a stalled connection otherwise waits for each idle
/// timeout in turn): its result, or nil. Returns on time even if the work ignores being
/// cancelled (it's left to finish on its own).
enum Deadline {
    static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let task = Task { await work() }
        let result: T? = await withCheckedContinuation { cont in
            let first = First(cont)
            Task { first.resume(await task.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                first.resume(nil)
            }
        }
        task.cancel()
        return result
    }

    /// Resumes with whichever answer comes first.
    private final class First<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T?, Never>?
        init(_ cont: CheckedContinuation<T?, Never>) { self.cont = cont }
        func resume(_ value: T?) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}

/// Requests to a provider: its key and headers on each, and every answer noted on its
/// account (so a revoked key or an empty wallet shows in Settings), and each failure kept so
/// the work that hit it can say so.
enum ProviderHTTP {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var troubles: [String: (ProviderTrouble, Date)] = [:]

    /// The last thing that went wrong with `providerID` after `since`, if anything did.
    static func trouble(for providerID: String, since: Date) -> ProviderTrouble? {
        lock.lock()
        defer { lock.unlock() }
        guard let (t, at) = troubles[providerID], at >= since else { return nil }
        return t
    }

    static func record(_ trouble: ProviderTrouble, for providerID: String) {
        lock.lock()
        troubles[providerID] = (trouble, Date())
        lock.unlock()
    }

    static func request(_ provider: any Provider, _ url: URL, key: String, timeout: TimeInterval,
                        contentType: String = "application/json") -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in provider.headers { req.setValue(value, forHTTPHeaderField: name) }
        return req
    }

    /// The answer and its status; nil when the provider couldn't be reached (offline, timed out).
    static func send(_ provider: any Provider, _ req: URLRequest, body: Data) async -> (data: Data, status: Int)? {
        guard let (data, resp) = try? await URLSession.shared.upload(for: req, from: body) else {
            record(.offline, for: provider.id)
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let trouble = ProviderTrouble(status: status) { record(trouble, for: provider.id) }
        Credentials.note(status: status, for: provider.id)
        return (data, status)
    }

    /// A JSON POST; the JSON answer when it succeeds, else nil (and the reason logged).
    static func post(_ provider: any Provider, _ url: URL, key: String, json: [String: Any],
                     timeout: TimeInterval = 60) async -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: json),
            let (data, status) = await send(provider, request(provider, url, key: key, timeout: timeout), body: body)
        else { return nil }
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.info("\(provider.id): HTTP \(status) from \(url.path): \(String(decoding: data.prefix(300), as: UTF8.self))")
            if status == 200 { record(.server(200), for: provider.id) }
            return nil
        }
        Credentials.noteWorking(provider.id)
        return obj
    }
}
