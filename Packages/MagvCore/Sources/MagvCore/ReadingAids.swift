import Foundation
import CoreGraphics

/// 再生間隔を有限の0.5〜100,000秒に制限し、0.5秒刻みの値だけを受け付ける。
public enum SlideshowInterval {
    public static let initial: Double = 5
    public static func parse(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite,
              (0.5...100_000).contains(value), (value * 2).rounded() == value * 2 else { return nil }
        return value
    }
}

/// 画像配置とルーペの幾何計算。描画処理から独立させ、同じ座標系で検証する。
public enum CanvasGeometry {
    /// 座標は画面倍率に依存しない論理ポイントで統一し、左上を原点とする。
    public static func imageRect(size: CGSize, slot: CGRect, position: Int, count: Int) -> CGRect {
        guard size.width > 0, size.height > 0, slot.width > 0, slot.height > 0 else { return .zero }
        let scale = min(slot.width / size.width, slot.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        // 単体は中央、見開きは左右の枠の内側へ寄せて、中央に綴じ目が来るように配置する。
        let x = count == 1 ? slot.midX - fitted.width / 2 : (position == 0 ? slot.maxX - fitted.width : slot.minX)
        return CGRect(x: x, y: slot.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
    public static func normalizedPoint(_ point: CGPoint, in image: CGRect) -> CGPoint? {
        guard image.width > 0, image.height > 0, image.contains(point) else { return nil }
        return CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
    }
    /// マウスが指す画像内の相対位置を、拡大後もレンズ中央に保つ。
    public static func magnifiedRect(image: CGRect, pointer: CGPoint, lens: CGRect, magnification: CGFloat = 8) -> CGRect? {
        guard let point = normalizedPoint(pointer, in: image) else { return nil }
        let size = CGSize(width: image.width * magnification, height: image.height * magnification)
        return CGRect(x: lens.midX - point.x * size.width, y: lens.midY - point.y * size.height, width: size.width, height: size.height)
    }
    /// ルーペ用の解像度を16メガピクセル相当に制限する。RGBAで約64MiBを目安とする。
    public static func loupePixelSize(metadata: ImageMetadata, displayed: CGSize, backingScale: CGFloat) -> Int {
        let aspect = CGFloat(max(metadata.width, metadata.height)) / CGFloat(max(1, min(metadata.width, metadata.height)))
        let bounded = sqrt(CGFloat(16 * 1024 * 1024) * aspect)
        let requested = max(displayed.width, displayed.height) * 8 * backingScale
        return max(1, Int(min(CGFloat(max(metadata.width, metadata.height)), 8192, bounded, requested)))
    }
}
