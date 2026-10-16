import Foundation
import CoreGraphics

public enum SlideshowInterval {
    public static let initial: Double = 5
    public static func parse(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite,
              (0.5...100_000).contains(value), (value * 2).rounded() == value * 2 else { return nil }
        return value
    }
}

public enum CanvasGeometry {
    /// All coordinates are logical points, with a top-left origin, independent of backing scale.
    public static func imageRect(size: CGSize, slot: CGRect, position: Int, count: Int) -> CGRect {
        guard size.width > 0, size.height > 0, slot.width > 0, slot.height > 0 else { return .zero }
        let scale = min(slot.width / size.width, slot.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let x = count == 1 ? slot.midX - fitted.width / 2 : (position == 0 ? slot.maxX - fitted.width : slot.minX)
        return CGRect(x: x, y: slot.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
    public static func normalizedPoint(_ point: CGPoint, in image: CGRect) -> CGPoint? {
        guard image.width > 0, image.height > 0, image.contains(point) else { return nil }
        return CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
    }
    public static func magnifiedRect(image: CGRect, pointer: CGPoint, lens: CGRect, magnification: CGFloat = 8) -> CGRect? {
        guard let point = normalizedPoint(pointer, in: image) else { return nil }
        let size = CGSize(width: image.width * magnification, height: image.height * magnification)
        return CGRect(x: lens.midX - point.x * size.width, y: lens.midY - point.y * size.height, width: size.width, height: size.height)
    }
    /// Bound the separate loupe decode to 16 megapixels (at most 64MiB of RGBA pixels).
    public static func loupePixelSize(metadata: ImageMetadata, displayed: CGSize, backingScale: CGFloat) -> Int {
        let aspect = CGFloat(max(metadata.width, metadata.height)) / CGFloat(max(1, min(metadata.width, metadata.height)))
        let bounded = sqrt(CGFloat(16 * 1024 * 1024) * aspect)
        let requested = max(displayed.width, displayed.height) * 8 * backingScale
        return max(1, Int(min(CGFloat(max(metadata.width, metadata.height)), 8192, bounded, requested)))
    }
}
