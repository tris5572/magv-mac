import Foundation
import ImageIO

public struct DecodedImage: @unchecked Sendable {
    public let image: CGImage
    public var byteCount: Int { image.bytesPerRow * image.height }
}

public enum ImageDecoder {
    private static func source(at url: URL, limits: ReaderLimits) throws -> CGImageSource {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) <= limits.imageBytes else { throw ReaderError.limit("単一画像256MiB") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ReaderError.invalidImage(url.lastPathComponent) }
        return source
    }

    public static func metadata(at url: URL, limits: ReaderLimits = ReaderLimits()) throws -> ImageMetadata {
        let source = try source(at: url, limits: limits)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw ReaderError.invalidImage(url.lastPathComponent) }
        guard Int64(width) <= limits.imagePixels / Int64(height) else { throw ReaderError.limit("画像寸法100メガピクセル") }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? ImageMetadata(width: height, height: width) : ImageMetadata(width: width, height: height)
    }

    public static func decode(at url: URL, maxPixelSize: Int, limits: ReaderLimits = ReaderLimits()) throws -> DecodedImage {
        _ = try metadata(at: url, limits: limits)
        let source = try source(at: url, limits: limits)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, 8192))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReaderError.invalidImage(url.lastPathComponent)
        }
        return DecodedImage(image: image)
    }
}
