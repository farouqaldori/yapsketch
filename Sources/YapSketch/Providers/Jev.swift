import Foundation

/// Jev, TypeSafe's System One model (typed judgments, not generated text), through whichever
/// connected provider offers it: the one chosen in Settings, else the first.
enum Jev {
    struct Route {
        let provider: any Provider
        let key: String
        let endpoint: JevEndpoint
    }

    /// The chosen account's Jev, else another connected one; one that's out of funds or
    /// needs reconnecting only when there's nothing else.
    static func route() -> Route? {
        let offering = Providers.all.filter { $0.jev != nil && $0.key != nil }
        let chosen = UserDefaults.standard.string(forKey: "jevProvider")
        let ordered = offering.filter { $0.id == chosen } + offering.filter { $0.id != chosen }
        let p = ordered.first { Credentials.problem(for: $0.id) == nil } ?? ordered.first
        guard let p, let key = p.key, let endpoint = p.jev else { return nil }
        return Route(provider: p, key: key, endpoint: endpoint)
    }

    static var model: String { route()?.endpoint.model ?? "jev-1.14.0" }
    static func apiKey() -> String? { route()?.key }

    /// Whether `key` works at `url`: one tiny question.
    static func check(_ key: String, at url: URL, model: String) async -> KeyCheck {
        let body: [String: Any] = [
            "model": model, "state": [:] as [String: Any],
            "questions": [
                "ok": ["type": "noul", "instructions": "Is the sky above Earth blue on a clear day?", "criteria": ["true": "Yes.", "false": "No."]]
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .rejected }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, http) = try? await URLSession.shared.upload(for: req, from: data) else { return .unreachable }
        switch (http as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return .works
        case 402: return .outOfFunds
        case 401, 403: return .rejected
        default: return .unreachable
        }
    }

    /// A request with JSON questions; the response object, or nil.
    static func ask(_ body: [String: Any], key: String) async -> [String: Any]? {
        guard let route = route(), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let req = ProviderHTTP.request(route.provider, route.endpoint.url, key: key, timeout: 60)
        return await perform(route.provider, req, data, what: "\((body["questions"] as? [String: Any])?.count ?? 0) questions")
    }

    /// A request with pictures (`assets` naming each image's part), sent the way the route takes them.
    static func ask(_ body: [String: Any], images parts: [(String, Data)], key: String) async -> [String: Any]? {
        guard let route = route() else { return nil }
        let what = "\(parts.count) images"
        switch route.endpoint.images {
        case .inline:
            guard let data = try? JSONSerialization.data(withJSONObject: inlined(body, parts)) else { return nil }
            return await perform(route.provider, ProviderHTTP.request(route.provider, route.endpoint.url, key: key, timeout: 90), data, what: what)
        case .multipart:
            guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            let boundary = "yapsketch-\(UUID().uuidString)"
            var data = Data()
            func append(_ s: String) { data.append(Data(s.utf8)) }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n")
            data.append(json)
            append("\r\n")
            for (name, image) in parts {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
                data.append(image)
                append("\r\n")
            }
            append("--\(boundary)--\r\n")
            var req = ProviderHTTP.request(
                route.provider, route.endpoint.url, key: key, timeout: 90, contentType: "multipart/form-data; boundary=\(boundary)")
            req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
            return await perform(route.provider, req, data, what: what)
        }
    }

    /// The JSON with each image inline (`image_url`) where its placeholder is in the state.
    static func inlined(_ body: [String: Any], _ parts: [(String, Data)]) -> [String: Any] {
        let data = Dictionary(parts, uniquingKeysWith: { a, _ in a })
        let assets = (body["assets"] as? [String: [String: String]]) ?? [:]
        var inline: [String: Any] = [:]
        for (ref, asset) in assets {
            guard let part = asset["part"], let jpeg = data[part] else { continue }
            inline[ref] = ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
        }
        func replace(_ v: Any) -> Any {
            if let s = v as? String, let image = inline[s] { return image }
            if let d = v as? [String: Any] { return d.mapValues(replace) }
            if let a = v as? [Any] { return a.map(replace) }
            return v
        }
        var out = body
        out["assets"] = nil
        out["state"] = replace(body["state"] ?? [:])
        return out
    }

    /// Sends, retrying while the service is busy (429/529, backing off 1, 2, 4 s).
    private static func perform(_ provider: any Provider, _ req: URLRequest, _ data: Data, what: String) async -> [String: Any]? {
        let started = CFAbsoluteTimeGetCurrent()
        for attempt in 0..<4 {
            // A stalled connection gives up after two minutes, not an idle timeout per read.
            guard let (resp, status) = await Deadline.run(120, { await ProviderHTTP.send(provider, req, body: data) }) else {
                Log.info("jev: request failed")
                if ProviderHTTP.trouble(for: provider.id, since: Date(timeIntervalSinceNow: -125)) == nil {
                    ProviderHTTP.record(.offline, for: provider.id)
                }
                return nil
            }
            if status == 429 || status == 529 {
                guard attempt < 3 else { break }
                let wait = 1 << attempt
                Log.info("jev: busy (HTTP \(status)), retrying in \(wait)s")
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                continue
            }
            guard status == 200, let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else {
                Log.info("jev: HTTP \(status): \(String(decoding: resp.prefix(400), as: UTF8.self))")
                if status == 200 { ProviderHTTP.record(.server(200), for: provider.id) }
                return nil
            }
            Credentials.noteWorking(provider.id)
            Log.info(String(format: "jev: %@ answered in %.1fs", what, CFAbsoluteTimeGetCurrent() - started))
            return obj
        }
        return nil
    }
}
