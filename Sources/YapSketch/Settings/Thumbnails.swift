import AppKit
import ImageIO

/// Pictures for History, scaled down off the main thread and kept for a while.
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 200 << 20
        return c
    }()

    static func cached(_ url: URL, maxPixels: Int) -> NSImage? { cache.object(forKey: key(url, maxPixels)) }

    static func load(_ url: URL, maxPixels: Int) async -> NSImage? {
        if let hit = cached(url, maxPixels: maxPixels) { return hit }
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                let cg = CGImageSourceCreateThumbnailAtIndex(
                    src, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: key(url, maxPixels), cost: Int(image.size.width * image.size.height) * 4) }
        return image
    }

    private static func key(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.path)" as NSString }
}
