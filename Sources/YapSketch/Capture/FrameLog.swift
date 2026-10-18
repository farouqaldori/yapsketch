import Accelerate
import CoreVideo
import Foundation

/// Small grayscale frames of the screen, taken while recording (up to 8 a second, only when
/// the screen changes), so processing after the recording stops doesn't have to decode the
/// video for them. Also notes, as it goes, the moments the screen changed most.
///
/// `frames.gray`: per frame, the time (Float64, seconds), width and height (Int32) and the
/// pixels (one byte each). `changes.json`: [[t, size]] of the changes found.
final class LiveFrames {
    /// Nil once closed: frames from a capture that started late, after giving up on it, are dropped.
    private var file: FileHandle?
    private let changesURL: URL
    private let clock: () -> Double
    private let pointer: (Double) -> CGPoint?
    private let display: CGSize
    private let queue = DispatchQueue(label: "yapsketch.frames", qos: .utility)
    private var lastTaken = -Double.infinity
    private var previous: (t: Double, g: ScreenDiff.Gray)?
    private var changes: [[Double]] = []
    private var taken = 0
    private var formatLogged = false
    private let lock = NSLock()

    init(dir: URL, display: CGSize, clock: @escaping () -> Double, pointer: @escaping (Double) -> CGPoint?) {
        let url = dir.appendingPathComponent("frames.gray")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        changesURL = dir.appendingPathComponent("changes.json")
        self.clock = clock
        self.pointer = pointer
        self.display = display
    }

    /// A frame from the capture stream (called for every frame; takes at most 8 a second).
    func add(_ pixels: CVPixelBuffer) {
        let t = clock()
        guard t - lastTaken >= 0.125 else { return }
        if !formatLogged {
            formatLogged = true
            let f = CVPixelBufferGetPixelFormatType(pixels)
            let code = String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xff) }, encoding: .ascii) ?? "\(f)"
            Log.info("frame log: capture frames are \(code), \(CVPixelBufferGetWidth(pixels))×\(CVPixelBufferGetHeight(pixels))")
        }
        guard let fine = Self.gray(pixels, width: 640) else { return }
        add(fine, at: t)
    }

    /// A frame already made small (640 px wide gray), at `t`.
    private func add(_ fine: ScreenDiff.Gray, at t: Double) {
        guard t - lastTaken >= 0.125 else { return }
        lastTaken = t
        taken += 1
        queue.async { [self] in
            // The change since the last frame, on a fine grid (a list's check marks
            // resetting is a small change), ignoring around the pointer.
            if let p = previous {
                let around = [pointer(p.t), pointer(t)].compactMap { $0 }
                let n = ScreenDiff.changed(p.g, fine, ignoring: Self.fineCells(around: around, display: display), cols: 64, rows: 40).count
                if n >= 6 {
                    lock.lock()
                    changes.append([t, Double(n)])
                    lock.unlock()
                }
            }
            previous = (t, fine)
            // Kept at half that size for the rest (settling, in-between states).
            let small = Self.half(fine)
            var header = Data()
            withUnsafeBytes(of: t) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(small.w)) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(small.h)) { header.append(contentsOf: $0) }
            // The throwing write: the old one raises an exception (a crash) on a full disk.
            try? file?.write(contentsOf: header + Data(small.px))
        }
    }

    func close() {
        queue.sync {
            try? file?.close()
            file = nil
            lock.lock()
            let found = changes
            lock.unlock()
            try? JSONEncoder().encode(found).write(to: changesURL)
            Log.info("frame log: \(taken) frames, \(found.count) changes")
        }
    }

    /// A screen frame as 8-bit gray, `width` pixels wide.
    static func gray(_ pixels: CVPixelBuffer, width: Int) -> ScreenDiff.Gray? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        // YUV (what the capture usually delivers): the first plane is already the gray.
        if CVPixelBufferIsPlanar(pixels), let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
            let w = CVPixelBufferGetWidthOfPlane(pixels, 0)
            let h = CVPixelBufferGetHeightOfPlane(pixels, 0)
            guard w > 0, h > 0 else { return nil }
            let dw = width
            let dh = max(1, Int(Double(h) * Double(width) / Double(w)))
            var src = vImage_Buffer(
                data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            )
            var out = [UInt8](repeating: 0, count: dw * dh)
            let ok: Bool = out.withUnsafeMutableBytes { o in
                var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw)
                return vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
            return ok ? ScreenDiff.Gray(px: out, w: dw, h: dh) : nil
        }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        guard w > 0, h > 0 else { return nil }
        let dw = width
        let dh = max(1, Int(Double(h) * Double(width) / Double(w)))
        var src = vImage_Buffer(
            data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pixels))
        var scaled = [UInt8](repeating: 0, count: dw * dh * 4)
        var out = [UInt8](repeating: 0, count: dw * dh)
        let ok: Bool = scaled.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { o in
                var mid = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw * 4)
                var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw)
                guard vImageScale_ARGB8888(&src, &mid, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
                // Luminance from B, G, R (memory order), out of 256.
                let matrix: [Int16] = [29, 150, 77, 0]
                return vImageMatrixMultiply_ARGB8888ToPlanar8(&mid, &dst, matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
                    == kvImageNoError
            }
        }
        return ok ? ScreenDiff.Gray(px: out, w: dw, h: dh) : nil
    }

    /// Half the size, each pixel the average of four.
    static func half(_ g: ScreenDiff.Gray) -> ScreenDiff.Gray {
        let w = g.w / 2
        let h = g.h / 2
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * g.w + 2 * x
                px[y * w + x] = UInt8((Int(g.px[i]) + Int(g.px[i + 1]) + Int(g.px[i + g.w]) + Int(g.px[i + g.w + 1])) / 4)
            }
        }
        return ScreenDiff.Gray(px: px, w: w, h: h)
    }

    /// Cells of the fine 64×40 grid within reach of the pointer (it moves).
    static func fineCells(around points: [CGPoint], display: CGSize) -> Set<Int> {
        var out = Set<Int>()
        for p in points {
            let cx = Int(p.x / display.width * 64)
            let cy = Int(p.y / display.height * 40)
            for dy in -2...2 {
                for dx in -2...2 where (0..<64).contains(cx + dx) && (0..<40).contains(cy + dy) { out.insert((cy + dy) * 64 + cx + dx) }
            }
        }
        return out
    }
}

/// The frames `LiveFrames` saved, for processing: the screen at any moment is the last
/// frame taken at or before it (frames only come when the screen changes).
struct FrameLog {
    let times: [Double]
    let frames: [ScreenDiff.Gray]
    /// [t, size] of the changes noticed while recording.
    let changes: [[Double]]

    static func load(from dir: URL) -> FrameLog? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("frames.gray"), options: .alwaysMapped), !data.isEmpty
        else { return nil }
        // Written when the recording closes: none after a crash.
        let changes = (try? Data(contentsOf: dir.appendingPathComponent("changes.json")))
            .flatMap { try? JSONDecoder().decode([[Double]].self, from: $0) } ?? []
        var times: [Double] = []
        var frames: [ScreenDiff.Gray] = []
        var i = 0
        while i + 16 <= data.count {
            let t = data.subdata(in: i..<(i + 8)).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            let w = Int(data.subdata(in: (i + 8)..<(i + 12)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            let h = Int(data.subdata(in: (i + 12)..<(i + 16)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
            i += 16
            guard w > 0, h > 0, i + w * h <= data.count else { break }
            times.append(t)
            frames.append(ScreenDiff.Gray(px: [UInt8](data.subdata(in: i..<(i + w * h))), w: w, h: h))
            i += w * h
        }
        return times.isEmpty ? nil : FrameLog(times: times, frames: frames, changes: changes)
    }

    /// The screen at `t`.
    func at(_ t: Double) -> ScreenDiff.Gray? {
        var lo = 0
        var hi = times.count - 1
        guard hi >= 0 else { return nil }
        guard times[0] <= t else { return frames[0] }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo]
    }
}
