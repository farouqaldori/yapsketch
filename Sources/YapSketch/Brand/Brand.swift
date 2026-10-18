import AppKit
import CoreText
import SwiftUI

/// YapSketch's look, the same as the website's: paper and ink, a coral dot, a little sun.
/// Fraunces for headings, Geist for everything else, Geist Mono for keys and ids (all three
/// bundled, under the OFL); New York, SF and SF Mono if they can't be loaded.
enum Brand {
    // MARK: Colours

    static let paper = hex(0xfaf5ec)
    /// Sidebars, and the wash behind pictures.
    static let panel = hex(0xf3eadc)
    static let card = hex(0xfffdf9)
    static let line = hex(0xe7dccb)
    /// Between rows of a card, and the track of a segmented control.
    static let rule = hex(0xefe6d8)
    static let ink = hex(0x23263a)
    /// Text that's ink but quieter: sidebar items, a list's unselected rows.
    static let inkSoft = hex(0x4b4e63)
    static let soft = hex(0x8a8272)
    /// A step not reached yet; a switch that's off.
    static let faint = hex(0xc9bda8)
    static let off = hex(0xe3d8c6)
    /// A drag handle's dots.
    static let grip = hex(0xa89f8e)
    static let coral = hex(0xff5240)
    static let coralText = hex(0xc8382a)
    static let coralWash = hex(0xfff7f5)
    static let sun = hex(0xffc53d)
    static let done = hex(0x2f9e5b)
    static let doneText = hex(0x1f6b3d)
    static let doneWash = hex(0xeef7f1)

    /// The recording toolbar, its pills and tips: one flat, neutral near-black.
    static let chrome = hex(0x1c1c1e)
    /// Its edge: a faint light line, so it holds against dark screens.
    static let chromeEdge = NSColor(white: 1, alpha: 0.09)
    /// Icons and the clock on it.
    static let onInkSoft = hex(0xa1a1a6)
    /// "Done" on ink: brighter than `done`, so it reads on the dark pill.
    static let doneOnInk = hex(0x43c26b)

    /// The other inks you can draw with (coral and sun first); bright, to read on any screen.
    static let markGreen = hex(0x5fcf80)
    static let markBlue = hex(0x6aa8ff)

    /// The app icon's tile.
    static let markPaper = hex(0xfdf8f0)
    /// Shadows on paper are warm, never grey.
    static let shade = hex(0x7a5a3c)

    // MARK: Layout

    /// Where a window's header line starts (clear of the traffic lights) and how tall it is:
    /// the sidebar's mark and each page's title sit centred on it.
    static let headerTop: CGFloat = 46
    /// Where every page's title starts, so switching pages doesn't move it.
    static let pageInset: CGFloat = 36
    static let headerHeight: CGFloat = 36

    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255,
            alpha: alpha)
    }

    // MARK: Fonts

    /// Loads the bundled fonts for this process (once).
    static func registerFonts() { _ = registered }

    private static let registered: Bool = {
        var dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts")]
        #if DEBUG
        // `swift run` and the snapshots: straight from the source tree.
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Resources/Fonts"))
        #endif
        guard let dir = dirs.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Geist.ttf").path) })
        else {
            Log.info("brand fonts not found; using the system's")
            return false
        }
        for name in ["Fraunces", "Geist", "GeistMono"] {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(dir.appendingPathComponent("\(name).ttf") as CFURL, .process, &error),
                let e = error?.takeRetainedValue(), CFErrorGetCode(e) != CTFontManagerError.alreadyRegistered.rawValue
            {
                Log.info("couldn't load \(name): \(e)")
            }
        }
        return true
    }()

    /// Fraunces, soft (as on the website), its optical size following the point size.
    static func serif(_ size: CGFloat) -> NSFont {
        registerFonts()
        let axes: [UInt32: CGFloat] = [tag("opsz"): min(max(size, 9), 144), tag("wght"): 400, tag("SOFT"): 100]
        let d = NSFontDescriptor(fontAttributes: [.family: "Fraunces", kCTFontVariationAttribute as NSFontDescriptor.AttributeName: axes])
        if let f = NSFont(descriptor: d, size: size), f.familyName == "Fraunces" { return f }
        let system = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        return system.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    /// Geist, for everything that isn't a heading.
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        variable("Geist", size, weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Geist Mono: keys, ids, the clock, section labels.
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        variable("Geist Mono", size, weight) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func variable(_ family: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        registerFonts()
        // Geist's weight axis runs 100–900; NSFont.Weight runs -1…1 with regular at 0.
        let wght: CGFloat =
            switch weight {
            case .medium: 500
            case .semibold: 600
            case .bold, .heavy, .black: 700
            case .light, .thin, .ultraLight: 300
            default: 400
            }
        let d = NSFontDescriptor(fontAttributes: [.family: family, kCTFontVariationAttribute as NSFontDescriptor.AttributeName: [tag("wght"): wght]])
        guard let f = NSFont(descriptor: d, size: size), f.familyName == family else { return nil }
        return f
    }

    private static func tag(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

extension ShapeStyle where Self == Color {
    static var paper: Color { Color(nsColor: Brand.paper) }
    static var panel: Color { Color(nsColor: Brand.panel) }
    static var card: Color { Color(nsColor: Brand.card) }
    static var line: Color { Color(nsColor: Brand.line) }
    static var rule: Color { Color(nsColor: Brand.rule) }
    static var ink: Color { Color(nsColor: Brand.ink) }
    static var inkSoft: Color { Color(nsColor: Brand.inkSoft) }
    static var soft: Color { Color(nsColor: Brand.soft) }
    static var faint: Color { Color(nsColor: Brand.faint) }
    static var off: Color { Color(nsColor: Brand.off) }
    static var grip: Color { Color(nsColor: Brand.grip) }
    static var coral: Color { Color(nsColor: Brand.coral) }
    static var coralText: Color { Color(nsColor: Brand.coralText) }
    static var coralWash: Color { Color(nsColor: Brand.coralWash) }
    static var sun: Color { Color(nsColor: Brand.sun) }
    static var done: Color { Color(nsColor: Brand.done) }
    static var doneText: Color { Color(nsColor: Brand.doneText) }
    static var doneWash: Color { Color(nsColor: Brand.doneWash) }
    static var shade: Color { Color(nsColor: Brand.shade) }
}

extension Font {
    static func serif(_ size: CGFloat) -> Font { Font(Brand.serif(size)) }
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font { Font(Brand.ui(size, weight)) }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font { Font(Brand.mono(size, weight)) }
}
