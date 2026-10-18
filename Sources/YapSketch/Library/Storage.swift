import AppKit

/// Recordings on disk: how much room they take, and deleting the old ones (a setting).
enum Storage {
    /// Days to keep a recording; 0 keeps them forever.
    static var keepDays: Int { UserDefaults.standard.integer(forKey: "keepDays") }

    private static let folderDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// When a recording started, from its folder's name.
    static func date(of dir: URL) -> Date? { folderDate.date(from: dir.lastPathComponent) }

    /// The recordings older than `days`, oldest first. (Folders are named by when they started.)
    static func older(than days: Int) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: AppDelegate.sessionsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { d in date(of: d).map { $0 < cutoff } ?? false }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Dictation files (audio and text, named by when) older than `days`.
    static func olderDictations(than days: Int) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: DictationHistory.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { f in date(of: f.deletingPathExtension()).map { $0 < cutoff } ?? false }
    }

    /// Deletes the recordings past the setting, never `keeping` (the one being made).
    static func cleanUp(keeping: URL? = nil) {
        let days = keepDays
        DispatchQueue.global(qos: .utility).async {
            let old = older(than: days).filter { $0.standardizedFileURL != keeping?.standardizedFileURL }
            for d in old + olderDictations(than: days) { try? FileManager.default.removeItem(at: d) }
            if !old.isEmpty { Log.info("storage: deleted \(old.count) recording(s) older than \(days) days") }
        }
    }

    /// The bytes all recordings take.
    static func usedBytes() -> Int64 {
        let e = FileManager.default.enumerator(at: AppDelegate.sessionsRoot, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let u = e?.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
