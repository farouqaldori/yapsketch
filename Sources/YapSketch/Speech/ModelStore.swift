import CryptoKit
import Foundation

/// A transcribe.cpp GGUF from the `handy-computer` repos on Hugging Face, pinned to a
/// commit and checked against its SHA-256 so a model never changes under the app.
struct SpeechModel: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    /// Streams, so it can do live captions.
    let live: Bool
    let repo: String
    let revision: String
    let file: String
    let bytes: Int64
    let sha256: String
    let license: String
    let licenseURL: String
    let credit: String

    var downloadURL: URL { URL(string: "https://huggingface.co/handy-computer/\(repo)/resolve/\(revision)/\(file)")! }
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    nonisolated static let catalog: [SpeechModel] = [
        SpeechModel(
            id: "parakeet-unified", name: "Parakeet Unified 0.6B", detail: "English · live captions", live: true,
            repo: "parakeet-unified-en-0.6b-gguf", revision: "843b1b175ace04f5a89d379c79e2518c0d065b25",
            file: "parakeet-unified-en-0.6b-Q8_0.gguf", bytes: 731_357_568,
            sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",
            license: "NVIDIA Open Model License",
            licenseURL: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/",
            credit: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License"),
        SpeechModel(
            id: "nemotron-streaming", name: "Nemotron Streaming 0.6B", detail: "English · live captions", live: true,
            repo: "nemotron-speech-streaming-en-0.6b-gguf", revision: "7df420cc3fb915a3b334560dac712af44fc41ef5",
            file: "nemotron-speech-streaming-en-0.6b-Q8_0.gguf", bytes: 729_650_176,
            sha256: "90d8c89714cd31efc88be62a40c6b2bea57e0cc2063af1ffe2c28f1a228ca110",
            license: "NVIDIA Open Model License",
            licenseURL: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/",
            credit: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License"),
        SpeechModel(
            id: "parakeet-v3", name: "Parakeet 0.6B v3", detail: "25 European languages", live: false,
            repo: "parakeet-tdt-0.6b-v3-gguf", revision: "d8d8c32cb2017c57e5307767343e97870f8a7f53",
            file: "parakeet-tdt-0.6b-v3-Q8_0.gguf", bytes: 739_508_576,
            sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
            license: "CC BY 4.0", licenseURL: "https://creativecommons.org/licenses/by/4.0/",
            credit: "Parakeet by NVIDIA, CC BY 4.0"),
        SpeechModel(
            id: "whisper-turbo", name: "Whisper Large v3 Turbo", detail: "99 languages", live: false,
            repo: "whisper-large-v3-turbo-gguf", revision: "18ada752005f5fddef499256f9a458d0b37a203a",
            file: "whisper-large-v3-turbo-Q8_0.gguf", bytes: 886_381_728,
            sha256: "257aa7ec9121c22c167d5e2c49e3e76b4ba0e6e27ebc13074eba0a80f8190220",
            license: "MIT", licenseURL: "https://github.com/openai/whisper/blob/main/LICENSE",
            credit: "Whisper by OpenAI, MIT"),
        SpeechModel(
            id: "whisper-small", name: "Whisper Small", detail: "99 languages · lighter", live: false,
            repo: "whisper-small-gguf", revision: "4afdc7942ecf1997f359deae48a63506b062eac4",
            file: "whisper-small-Q8_0.gguf", bytes: 269_751_136,
            sha256: "9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860",
            license: "Apache 2.0", licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
            credit: "Whisper by OpenAI"),
    ]

    /// Download progress (0…1) by model id; a model being checked after download shows 1.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var installed: Set<String> = []
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "modelID") }
    }
    @Published private(set) var failed: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    nonisolated static var folder: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/YapSketch/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func file(for model: SpeechModel) -> URL { folder.appendingPathComponent(model.file) }

    private override init() {
        selectedID = UserDefaults.standard.string(forKey: "modelID") ?? "parakeet-unified"
        super.init()
        refresh()
    }

    func refresh() {
        installed = Set(
            Self.catalog.filter { m in
                ((try? FileManager.default.attributesOfItem(atPath: Self.file(for: m).path)[.size]) as? Int64) == m.bytes
            }.map(\.id))
    }

    /// The model to use: the selected one if it's here, else any that is.
    nonisolated static func currentFile() -> URL? {
        let fm = FileManager.default
        let selected = UserDefaults.standard.string(forKey: "modelID") ?? "parakeet-unified"
        let ordered = catalog.filter { $0.id == selected } + catalog.filter { $0.id != selected }
        return ordered.map(file(for:)).first { fm.fileExists(atPath: $0.path) }
    }

    nonisolated static func current() -> SpeechModel? {
        guard let f = currentFile() else { return nil }
        return catalog.first { $0.file == f.lastPathComponent }
    }

    nonisolated private static func resumeFile(for m: SpeechModel) -> URL { folder.appendingPathComponent(m.file + ".resume") }

    func download(_ m: SpeechModel) {
        guard tasks[m.id] == nil else { return }
        failed[m.id] = nil
        progress[m.id] = 0
        let resume = try? Data(contentsOf: Self.resumeFile(for: m))
        try? FileManager.default.removeItem(at: Self.resumeFile(for: m))
        Log.info("models: \(resume == nil ? "downloading" : "resuming") \(m.file)")
        let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: m.downloadURL)
        task.taskDescription = m.id
        tasks[m.id] = task
        task.resume()
    }

    func cancel(_ m: SpeechModel) {
        try? FileManager.default.removeItem(at: Self.resumeFile(for: m))
        tasks[m.id]?.cancel()
        tasks[m.id] = nil
        progress[m.id] = nil
    }

    func delete(_ m: SpeechModel) {
        try? FileManager.default.removeItem(at: Self.file(for: m))
        refresh()
    }

    // MARK: URLSessionDownloadDelegate (on the main queue)

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (Self.catalog.first { $0.id == id }?.bytes ?? 1)
        MainActor.assumeIsolated { progress[id] = min(0.99, Double(totalBytesWritten) / Double(total)) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let m = Self.catalog.first(where: { $0.id == id }) else { return }
        // An error page isn't the model.
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            Log.info("models: \(m.file): HTTP \(status)")
            MainActor.assumeIsolated {
                tasks[id] = nil
                progress[id] = nil
                failed[id] = "Couldn't download it (the server said \(status)). Try again later."
            }
            return
        }
        // Moved out of the temporary location now (it's deleted when this returns), then checked.
        let staged = Self.folder.appendingPathComponent(m.file + ".download")
        try? FileManager.default.removeItem(at: staged)
        let moved = (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        Task.detached {
            let ok = moved && Self.sha256(of: staged) == m.sha256
            if ok {
                try? FileManager.default.removeItem(at: Self.file(for: m))
                try? FileManager.default.moveItem(at: staged, to: Self.file(for: m))
            } else {
                try? FileManager.default.removeItem(at: staged)
            }
            Log.info("models: \(m.file) \(ok ? "downloaded and checked" : "failed the check")")
            await MainActor.run {
                self.tasks[id] = nil
                self.progress[id] = nil
                if !ok { self.failed[id] = "The download was damaged. Try again." }
                self.refresh()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        // What came down so far is kept, so trying again picks up from there.
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        if let resume, let m = Self.catalog.first(where: { $0.id == id }) { try? resume.write(to: Self.resumeFile(for: m)) }
        MainActor.assumeIsolated {
            tasks[id] = nil
            progress[id] = nil
            if (error as NSError).code != NSURLErrorCancelled {
                let why = (error as? URLError)?.code == .notConnectedToInternet ? "You're offline." : error.localizedDescription
                failed[id] = resume == nil ? "\(why) Try again." : "\(why) Try again to pick up where it stopped."
                Log.info("models: download failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
