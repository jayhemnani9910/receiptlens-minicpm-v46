import UIKit
import ImageIO

/// In-memory, downsampled thumbnail cache for History rows.
/// Thread-safe via NSCache; decoding happens off the main actor.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    /// Returns a cached thumbnail or decodes one. `maxPixel` is in points;
    /// it is multiplied by the screen scale internally.
    func thumbnail(for url: URL, maxPixel: CGFloat = 120) async -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let scale = await UIScreen.main.scale
        let image = await Task.detached(priority: .utility) {
            Self.downsample(url: url, maxPixelSize: maxPixel * scale)
        }.value

        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func remove(filename: String) {
        cache.removeObject(forKey: filename as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private static func downsample(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
