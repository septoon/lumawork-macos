import AppKit
import ImageIO

// Decode thumbnails at display size, never a full-resolution bitmap for a list row.
enum MacImageAdapter {
    private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>(); value.totalCostLimit = 24 * 1024 * 1024; value.countLimit = 80; return value
    }()
    static func thumbnail(file: URL, maximumPixelSize: Int = 360) -> NSImage? {
        let pixels = min(1600, max(32, maximumPixelSize))
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
        let key = (file.path + "|\(pixels)|\(stamp?.fileSize ?? 0)|\(stamp?.contentModificationDate?.timeIntervalSince1970 ?? 0)") as NSString
        if let value = cache.object(forKey: key) { return value }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height); return result
    }
    static func remove(file: URL) { cache.removeAllObjects() } // Protected previews must leave no retained decoded image.
}
