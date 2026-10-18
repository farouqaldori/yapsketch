import AppKit
import Foundation

/// A key comes from `<ID>_API_KEY`, else the Keychain item `com.yapsketch.<id>` (cached after
/// the first read).
enum Credentials {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func key(for id: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["\(id.uppercased())_API_KEY"], !env.isEmpty { return env }
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[id] { return known }
        let key = Keychain.read("com.yapsketch.\(id)")
        cache[id] = .some(key)
        return key
    }

    static func save(_ signedIn: SignedIn?, for id: String) {
        lock.lock()
        cache[id] = nil
        lock.unlock()
        Keychain.write("com.yapsketch.\(id)", signedIn?.key)
        UserDefaults.standard.set(signedIn?.user, forKey: "\(id)User")
        UserDefaults.standard.removeObject(forKey: "\(id)Problem")
        NotificationCenter.default.post(name: .yapSketchAccountsChanged, object: nil)
    }

    static func user(for id: String) -> String? { UserDefaults.standard.string(forKey: "\(id)User") }

    static func problem(for id: String) -> AccountProblem? {
        UserDefaults.standard.string(forKey: "\(id)Problem").map { $0 == "disconnected" ? .disconnected : .outOfFunds }
    }

    /// 401 means the key was revoked, 402 that the account is out of funds.
    static func note(status: Int, for id: String) {
        switch status {
        case 401: set(.disconnected, for: id)
        case 402: set(.outOfFunds, for: id)
        default: break
        }
    }

    /// Call after a real answer, not just a 200.
    static func noteWorking(_ id: String) { set(nil, for: id) }

    private static func set(_ new: AccountProblem?, for id: String) {
        guard new != problem(for: id) else { return }
        UserDefaults.standard.set(new.map { $0 == .disconnected ? "disconnected" : "outOfFunds" }, forKey: "\(id)Problem")
        NotificationCenter.default.post(name: .yapSketchAccountsChanged, object: nil)
    }
}

enum AccountProblem { case disconnected, outOfFunds }

@MainActor
final class Account: ObservableObject, Identifiable {
    enum State: Equatable {
        case off
        case signingIn(SignInPage?)
        case connected(user: String?)
    }

    let provider: any Provider
    nonisolated var id: String { provider.id }
    @Published private(set) var state: State = .off
    @Published private(set) var problem: AccountProblem?
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(_ provider: any Provider) {
        self.provider = provider
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .yapSketchAccountsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        problem = Credentials.problem(for: id)
        if case .signingIn = state { return }
        state = provider.isConnected ? .connected(user: Credentials.user(for: id)) : .off
    }

    func signIn() {
        guard case .browser(let run) = provider.connect else { return }
        task?.cancel()
        error = nil
        state = .signingIn(nil)
        task = Task {
            do {
                let signedIn = try await run { page in
                    Task { @MainActor in
                        self.state = .signingIn(page)
                        NSWorkspace.shared.open(page.url)
                    }
                }
                Credentials.save(signedIn, for: id)
                Log.info("\(id): connected")
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            state = .off
            refresh()
        }
    }

    /// A working key on an empty account is saved too, marked out of funds.
    func save(key: String) async -> KeyCheck {
        guard case .apiKey(_, let check) = provider.connect else { return .rejected }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .rejected }
        let result = await check(key)
        if result == .works || result == .outOfFunds {
            Credentials.save(SignedIn(key: key), for: id)
            if result == .outOfFunds { Credentials.note(status: 402, for: id) }
        }
        return result
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .off
        refresh()
    }

    func disconnect() {
        Credentials.save(nil, for: id)
        CloudSpeech.forget(provider)
    }
}

@MainActor
final class Accounts {
    static let shared = Accounts()
    let all: [Account] = Providers.all.map(Account.init)
}

enum Keychain {
    static func read(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func write(_ service: String, _ key: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum ProviderLogo {
    static func image(_ id: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Providers") {
            return NSImage(contentsOf: url)
        }
        #if DEBUG
        // Run from .build with no app bundle.
        var repo = URL(fileURLWithPath: #filePath)
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.swift").path) {
            repo.deleteLastPathComponent()
        }
        return NSImage(contentsOf: repo.appendingPathComponent("Resources/Providers/\(id).png"))
        #else
        return nil
        #endif
    }

    static func menuIcon(_ id: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            if let image = image(id) {
                image.draw(in: rect)
            } else {
                NSColor.secondaryLabelColor.setFill()
                rect.fill()
            }
            return true
        }
    }
}

extension Notification.Name {
    static let yapSketchAccountsChanged = Notification.Name("yapSketchAccountsChanged")
}
