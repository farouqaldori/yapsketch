import Foundation
import QuartzCore

enum EventKind: String, Codable {
    case sessionStart, sessionEnd
    case click, keys, shortcut
    case appSwitch, window
    case annotation, textNote, clear
    /// A temporary-ink stroke faded away (`id` is the stroke's).
    case erase
    /// A JavaScript error in the browser tab (`text`).
    case console
    /// The user circled or wiggled the mouse pointer over `bbox` from `t0` to `t`: pointing
    /// at something (found afterwards from the pointer's path).
    case gesture
    /// The user scrolled (logged at most every 0.2 s while scrolling).
    case scroll
}

/// One thing that happened during a recording. Coordinates are in points,
/// relative to the top-left of the recorded display.
struct SessionEvent: Codable {
    var t: Double
    var kind: EventKind
    var x: Double?
    var y: Double?
    var button: String?
    var text: String?
    var app: String?
    var window: String?
    var url: String?
    var element: String?
    var tool: String?
    var color: String?
    var bbox: [Double]?
    /// Which stroke a drawn mark is, and an erase's (the stroke that faded).
    var id: Int?
    /// When a drawing stroke began (`t` is when it ended).
    var t0: Double?

    init(t: Double, kind: EventKind) {
        self.t = t
        self.kind = kind
    }
}

struct TranscriptSegment: Codable {
    var start: Double
    var end: Double
    var text: String
    /// Word-level timings, when the engine provides them.
    var words: [TranscriptSegment]? = nil
}

/// Information about the display being recorded.
struct DisplayInfo: Codable {
    let displayID: CGDirectDisplayID
    /// Size of the recorded area in points (the whole screen, or one window).
    let size: CGSize
    let scale: CGFloat
    /// The recorded area in global Quartz coordinates (top-left origin of the main display).
    let globalBounds: CGRect
    /// The whole screen in global coordinates.
    let screen: CGRect

    /// Where the recorded area sits on the screen (zero when recording the whole screen).
    var captureOffset: CGPoint {
        CGPoint(x: globalBounds.minX - screen.minX, y: globalBounds.minY - screen.minY)
    }

    /// Global point -> coordinates in the recorded area (what the report and screenshots use).
    func toLocal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - globalBounds.origin.x, y: global.y - globalBounds.origin.y)
    }

    /// Global point -> coordinates on the screen (what the overlay draws in).
    func toScreen(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screen.origin.x, y: global.y - screen.origin.y)
    }

    func contains(_ global: CGPoint) -> Bool { globalBounds.contains(global) }
}

/// A recording session: owns the output folder, the clock, and the event log.
final class Session {
    let dir: URL
    let startedAt: Date
    let display: DisplayInfo

    private let lock = NSLock()
    private var t0: CFTimeInterval?
    private var _events: [SessionEvent] = []
    private var _liveTranscript: [TranscriptSegment] = []
    /// Mouse pointer samples [t, x, y] in recorded-area coordinates.
    private var _pointer: [[Double]] = []
    /// The event log, until it's closed (events after that are kept in memory only).
    private var logHandle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    var videoURL: URL { dir.appendingPathComponent("recording.mp4") }
    var micURL: URL { dir.appendingPathComponent("mic.m4a") }
    var eventsURL: URL { dir.appendingPathComponent("events.jsonl") }

    private struct Meta: Codable {
        var startedAt: Date
        var display: DisplayInfo
    }

    init(root: URL, display: DisplayInfo) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        startedAt = Date()
        dir = root.appendingPathComponent(f.string(from: startedAt), isDirectory: true)
        self.display = display
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(Meta(startedAt: startedAt, display: display)).write(to: dir.appendingPathComponent("session.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("events.jsonl").path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl"))
    }

    /// Re-opens a saved recording's folder (to make its report again).
    init(existing dir: URL) throws {
        self.dir = dir
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        startedAt = meta.startedAt
        display = meta.display
        logHandle = nil
        let lines = (try? String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        _events = lines.split(separator: "\n").compactMap { try? JSONDecoder().decode(SessionEvent.self, from: Data($0.utf8)) }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("live-transcript.json")) {
            _liveTranscript = (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("pointer.json")) {
            _pointer = (try? JSONDecoder().decode([[Double]].self, from: data)) ?? []
        }
    }

    /// Marks t = 0. Called when the first video frame is written.
    func markStart() {
        lock.lock()
        if t0 == nil { t0 = CACurrentMediaTime() }
        lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return t0 != nil
    }

    /// Seconds since recording started (0 before it starts).
    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let t0 else { return 0 }
        return max(0, CACurrentMediaTime() - t0)
    }

    func log(_ event: SessionEvent) {
        lock.lock()
        _events.append(event)
        if let data = try? encoder.encode(event) {
            try? logHandle?.write(contentsOf: data + Data("\n".utf8))
        }
        lock.unlock()
    }

    func addLiveTranscript(_ seg: TranscriptSegment) {
        lock.lock()
        _liveTranscript.append(seg)
        lock.unlock()
    }

    func addPointer(t: Double, at p: CGPoint) {
        lock.lock()
        if let last = _pointer.last, last[1] == Double(p.x), last[2] == Double(p.y) {
            lock.unlock()
            return
        }
        _pointer.append([t, Double(p.x).rounded(), Double(p.y).rounded()])
        lock.unlock()
    }

    /// Where the mouse pointer was at time t (the latest sample before it).
    func pointer(at t: Double) -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = _pointer.first else { return nil }
        // Binary search: the last sample at or before t.
        var lo = 0
        var hi = _pointer.count - 1
        guard _pointer[0][0] <= t else { return CGPoint(x: first[1], y: first[2]) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if _pointer[mid][0] <= t { lo = mid } else { hi = mid - 1 }
        }
        return CGPoint(x: _pointer[lo][1], y: _pointer[lo][2])
    }

    /// All pointer samples [t, x, y].
    var pointerSamples: [[Double]] {
        lock.lock()
        defer { lock.unlock() }
        return _pointer
    }

    var events: [SessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events.sorted { $0.t < $1.t }
    }

    var liveTranscript: [TranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        return _liveTranscript.sorted { $0.start < $1.start }
    }

    func close() {
        lock.lock()
        try? logHandle?.close()
        logHandle = nil
        let live = _liveTranscript.sorted { $0.start < $1.start }
        let pointer = _pointer
        lock.unlock()
        try? JSONEncoder().encode(live).write(to: dir.appendingPathComponent("live-transcript.json"))
        try? JSONEncoder().encode(pointer).write(to: dir.appendingPathComponent("pointer.json"))
    }
}

enum Fmt {
    /// 83.42 -> "01:23.4"
    static func clock(_ t: Double, decimals: Bool = true) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        if decimals { return String(format: "%02d:%04.1f", m, s) }
        return String(format: "%02d:%02d", m, Int(s))
    }

    static func srt(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
