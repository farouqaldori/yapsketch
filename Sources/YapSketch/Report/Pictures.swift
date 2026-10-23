import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture of the screen where the user drew or circled with the pointer.
struct ReportPicture {
    let n: Int
    /// Relative to the session folder.
    let path: String
    let t: Double
    /// The drawing or pointer circle it shows.
    let mark: SessionEvent
}

extension PostProcessor {
    /// One picture per drawing or pointer circle, at the moment it's whole: the circled spot lit,
    /// the number of the picture in a badge beside it, cropped to the window when that's well
    /// inside the screen.
    func pictures(asset: AVURLAsset, events: [SessionEvent], duration: Double) async -> [ReportPicture] {
        let dir = session.dir.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let display = session.display.size
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = display
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        var out: [ReportPicture] = []
        let marks = events.filter { Self.isMark($0) }.sorted { ($0.t0 ?? $0.t) < ($1.t0 ?? $1.t) }
        for mark in marks {
            let t = min(Self.shown(mark), max(0, duration - 0.05))
            guard var image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            if mark.kind == .gesture,
                let lit = PointerGestures.spotlightRegion(session.pointerSamples, from: mark.t0 ?? mark.t, to: mark.t, on: image, display: display),
                let shaded = PointerGestures.drawSpotlight([lit], on: image, display: display)
            {
                image = shaded
            }
            let n = out.count + 1
            let area = Self.area(mark)
            let spots = Badges.spots(area.map { [$0] } ?? [], display: display)
            guard let stamped = Badges.stamp(n, at: spots.isEmpty ? [Badges.corner] : spots, on: image, display: display) else { continue }
            let window = Self.window(at: t, events: events)
            let picture = Self.crop(stamped, to: window, keeping: area.map { [$0] } ?? [], display: display)
            let path = "shots/\(n).jpg"
            guard Self.write(picture, to: session.dir.appendingPathComponent(path)) else { continue }
            out.append(ReportPicture(n: n, path: path, t: t, mark: mark))
        }
        return out
    }

    static func isMark(_ e: SessionEvent) -> Bool { e.kind == .annotation || e.kind == .textNote || e.kind == .gesture }

    /// When a mark is best seen: just after a drawing is finished, or halfway through a pointer
    /// circle (it leaves no ink).
    static func shown(_ mark: SessionEvent) -> Double {
        mark.kind == .gesture ? ((mark.t0 ?? mark.t) + mark.t) / 2 : mark.t + 0.25
    }

    static func area(_ e: SessionEvent) -> CGRect? {
        guard let b = e.bbox, b.count == 4 else { return nil }
        return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
    }

    /// The front window's frame at `t`, as the last app or window change before then saw it.
    static func window(at t: Double, events: [SessionEvent]) -> CGRect? {
        events.last { Timeline.isPlace($0) && $0.t <= t + 0.05 }.flatMap(area)
    }

    /// `image` cut down to `window` (and the marks, wherever they are), when that leaves out at
    /// least a sixth of the screen; else the whole screen.
    static func crop(_ image: CGImage, to window: CGRect?, keeping marks: [CGRect], display: CGSize) -> CGImage {
        guard let window else { return image }
        let screen = CGRect(origin: .zero, size: display)
        let area = marks.reduce(window) { $0.union($1) }.insetBy(dx: -12, dy: -12).intersection(screen)
        guard !area.isNull, area.width * area.height < screen.width * screen.height * 5 / 6, area.width > 200, area.height > 150 else {
            return image
        }
        let s = Double(image.width) / display.width
        let px = CGRect(x: area.minX * s, y: area.minY * s, width: area.width * s, height: area.height * s).integral
        return image.cropping(to: px) ?? image
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
