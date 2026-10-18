import Foundation
import ImageIO

/// デコード済みの不変なCGImageと、実際の行幅に基づくメモリ使用量。
public struct DecodedImage: @unchecked Sendable {
    public let image: CGImage
    public var byteCount: Int { image.bytesPerRow * image.height }
}

/// Image I/Oで寸法を確認し、向きを補正した縮小画像を必要な解像度で生成する。
public enum ImageDecoder {
    private static func source(at url: URL, limits: ReaderLimits) throws -> CGImageSource {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) <= limits.imageBytes else { throw ReaderError.limit("単一画像256MiB") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ReaderError.invalidImage(url.lastPathComponent) }
        return source
    }

    /// 画像本体のデコード前にピクセル数を制限し、EXIFの回転を反映した縦横を返す。
    public static func metadata(at url: URL, limits: ReaderLimits = ReaderLimits()) throws -> ImageMetadata {
        let source = try source(at: url, limits: limits)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw ReaderError.invalidImage(url.lastPathComponent) }
        guard Int64(width) <= limits.imagePixels / Int64(height) else { throw ReaderError.limit("画像寸法100メガピクセル") }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // EXIFの向き5〜8では表示上の幅と高さが入れ替わるため、見開き判定にも反映する。
        return (5...8).contains(orientation) ? ImageMetadata(width: height, height: width) : ImageMetadata(width: width, height: height)
    }

    public static func decode(at url: URL, maxPixelSize: Int, limits: ReaderLimits = ReaderLimits(),
                              maximumBytes: Int = 128 * 1024 * 1024) throws -> DecodedImage {
        let metadata = try metadata(at: url, limits: limits)
        let source = try source(at: url, limits: limits)
        let aspect = Double(max(metadata.width, metadata.height)) / Double(min(metadata.width, metadata.height))
        // 通常のRGBAに加えて16bit画像も考慮し、1ピクセルあたり8バイトで安全側の上限を求める。
        let bounded = max(1, Int(sqrt(Double(max(8, maximumBytes)) / 8 * aspect)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, 8192, bounded))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReaderError.invalidImage(url.lastPathComponent)
        }
        let decoded = DecodedImage(image: image)
        guard decoded.byteCount <= maximumBytes else { throw ReaderError.limit("画像デコード用メモリ") }
        return decoded
    }
}
