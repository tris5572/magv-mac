import Foundation

public enum DisplayMode: String, CaseIterable, Codable, Sendable { case single, spread }
public enum ReadingDirection: String, CaseIterable, Codable, Sendable { case rightToLeft, leftToRight }
public enum ImageOrientation: Sendable { case portrait, landscape, unknown }
public enum PageCommand: CaseIterable, Sendable { case next, previous, nextImage, previousImage, first, last }
public enum SourceCommand: CaseIterable, Sendable { case next, previous, random }

public struct DisplayPage: Equatable, Sendable {
    public let anchorIndex: Int
    public let visibleIndices: [Int]
    public let forceSingle: Bool

    public init(anchorIndex: Int, visibleIndices: [Int], forceSingle: Bool = false) {
        self.anchorIndex = anchorIndex
        self.visibleIndices = visibleIndices
        self.forceSingle = forceSingle
    }
}

public struct ImageMetadata: Sendable {
    public let width: Int
    public let height: Int
    public var orientation: ImageOrientation { width < height ? .portrait : .landscape }
}

public struct ImageEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let fileURL: URL
    public var metadata: ImageMetadata?
    public var failure: String?
    public var orientation: ImageOrientation { metadata?.orientation ?? .unknown }
}

public enum SourceKind: Sendable { case archive, directory }

public struct LoadedSource: Sendable {
    public let url: URL
    public let kind: SourceKind
    public let images: [ImageEntry]
    public let initialIndex: Int?
    // Retains permission and temporary data for as long as the source is in use.
    public let access: FileAccessLease
    public let temporaryDirectory: TemporaryDirectory?
    public let siblings: [URL]
    public let needsParentAccess: Bool
    public let isPartialDirectory: Bool
    public let revision: FileRevision?
    public var title: String { url.lastPathComponent }

    public func relocated(to newURL: URL) -> LoadedSource {
        LoadedSource(url: newURL, kind: kind, images: images, initialIndex: initialIndex, access: access,
            temporaryDirectory: temporaryDirectory,
            siblings: siblings.map { FileAccessService.sameLocation($0, url) ? newURL : $0 }
                .sorted { SourceFormat.naturalOrder($0.lastPathComponent, $1.lastPathComponent) },
            needsParentAccess: needsParentAccess, isPartialDirectory: isPartialDirectory, revision: revision)
    }
}

public struct ReaderLimits: Sendable {
    public var entryCount = 100_000
    public var imageBytes: Int64 = 256 * 1024 * 1024
    public var imagePixels: Int64 = 100_000_000
    public var sourceBytes: Int64 = 10 * 1024 * 1024 * 1024
    public var temporaryBytes: Int64 = 2 * 1024 * 1024 * 1024
    public init() {}
}

public enum ReaderError: Error, LocalizedError, Equatable, Sendable {
    case unsupported, noImages, missing, permission
    case archive(String), encrypted, unsupportedCompression(String), unsafePath(String)
    case limit(String), invalidImage(String)
    case invalidName, sourceChanged, rename(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "対応形式はZIP、RAR、画像ファイル、画像フォルダです。"
        case .noImages: "表示できる画像がありません。"
        case .missing: "ファイルが見つかりません。もう一度選択してください。"
        case .permission: "アクセス権がありません。対象のファイルまたはフォルダを選択してください。"
        case .archive(let detail): "アーカイブを展開できません。\n\(detail)"
        case .encrypted: "暗号化されたアーカイブには対応していません。"
        case .unsupportedCompression(let detail): "分割アーカイブまたは未対応の圧縮方式です。\n\(detail)"
        case .unsafePath(let path): "安全でないアーカイブ内パスを検出しました。\n\(path)"
        case .limit(let name): "読み込み上限を超えました（\(name)）。"
        case .invalidImage(let name): "画像を読み込めません。\n\(name)"
        case .invalidName: "名前が空、または使用できない文字が含まれています。区切り文字や制御文字は使用できません。"
        case .sourceChanged: "ファイルが外部で変更されています。もう一度開いてから名前を変更してください。"
        case .rename(let detail): "名前を変更できません。\n\(detail)"
        }
    }
}

public enum SourceFormat {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff"]
    public static let archiveExtensions: Set<String> = ["zip", "rar"]
    public static func isImage(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }
    public static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        return comparison == .orderedSame ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : comparison == .orderedAscending
    }
}
