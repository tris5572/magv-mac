import Foundation

// 表示方法、開き方向、移動操作を共通の型で表し、UIとコア処理で共有する。
public enum DisplayMode: String, CaseIterable, Codable, Sendable { case single, spread }
public enum ReadingDirection: String, CaseIterable, Codable, Sendable { case rightToLeft, leftToRight }
public enum ImageOrientation: Sendable { case portrait, landscape, unknown }
public enum PageCommand: CaseIterable, Sendable { case next, previous, nextImage, previousImage, first, last }
public enum SourceCommand: CaseIterable, Sendable { case next, previous, random }

/// 0始まりの基準画像番号と、実際に表示する1枚または2枚の画像番号。
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

/// 画像一覧の1項目。未調査の画像はmetadataがnil、読み込み失敗はfailureに記録する。
public struct ImageEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    // アーカイブ内画像の実体は、preparingImagesが返したソースを保持している間だけ保証される。
    public let fileURL: URL
    public var metadata: ImageMetadata?
    public var failure: String?
    public var orientation: ImageOrientation { metadata?.orientation ?? .unknown }
}

public enum SourceKind: Sendable { case archive, directory }

/// 本の一覧情報とアクセス権・一時領域を共有する値。必要な画像を準備したコピーを返す。
public struct LoadedSource: Sendable {
    public let url: URL
    public let kind: SourceKind
    public internal(set) var images: [ImageEntry]
    public let initialIndex: Int?
    // ソースが利用されている間、アクセス権と一時展開データの所有権を保持する。
    public let access: FileAccessLease
    public let temporaryDirectory: TemporaryDirectory?
    public let siblings: [URL]
    public let needsParentAccess: Bool
    public let isPartialDirectory: Bool
    public let revision: FileRevision?
    public var title: String { url.lastPathComponent }
    public let archive: ArchiveImageStore?
    private var fileLeases: [ExtractionFileLease] = []

    /// 見開き判定に必要な画像情報を取得する。取得後のファイル保持は要求しない。
    public func preparingMetadata(at indices: [Int], prefetch: Bool = false) async throws -> LoadedSource {
        guard let archive else { return self }
        let prepared = try await archive.prepare(indices, files: false, speculative: prefetch)
        var result = self; result.images = prepared.images; return result
    }
    /// 指定画像のファイルを準備し、返したソースが保持されている間は削除から保護する。
    public func preparingImages(at indices: [Int], prefetch: Bool = false) async throws -> LoadedSource {
        guard let archive else { return self }
        let prepared = try await archive.prepare(indices, files: true, speculative: prefetch)
        var result = self; result.images = prepared.images; result.fileLeases = prepared.leases; return result
    }
    /// 先頭候補を確認してから必要な2枚目を準備し、横長や単体表示では余分な展開を避ける。
    public func preparingPage(at index: Int, mode: DisplayMode, prefetch: Bool = false) async throws -> LoadedSource {
        guard !images.isEmpty, archive != nil else { return self }
        let anchor = min(max(0, index), images.count - 1)
        let first = try await preparingImages(at: [anchor], prefetch: prefetch)
        guard mode == .spread, first.images[anchor].orientation == .portrait, anchor + 1 < images.count else { return first }
        let pair = try await first.preparingImages(at: [anchor, anchor + 1], prefetch: prefetch)
        return pair.images[anchor + 1].orientation == .portrait ? pair : try await pair.preparingImages(at: [anchor], prefetch: prefetch)
    }
    // 一覧キャッシュは画像ファイルを固定せず、容量不足時にページ単位で削除できるようにする。
    func unpinned() -> LoadedSource { var result = self; result.fileLeases = []; return result }
    init(url: URL, kind: SourceKind, images: [ImageEntry], initialIndex: Int?, access: FileAccessLease,
         temporaryDirectory: TemporaryDirectory?, siblings: [URL], needsParentAccess: Bool,
         isPartialDirectory: Bool, revision: FileRevision?, archive: ArchiveImageStore? = nil) {
        self.url = url; self.kind = kind; self.images = images; self.initialIndex = initialIndex; self.access = access
        self.temporaryDirectory = temporaryDirectory; self.siblings = siblings; self.needsParentAccess = needsParentAccess
        self.isPartialDirectory = isPartialDirectory; self.revision = revision; self.archive = archive
    }

    public func relocated(to newURL: URL) -> LoadedSource {
        var result = LoadedSource(url: newURL, kind: kind, images: images, initialIndex: initialIndex, access: access,
            temporaryDirectory: temporaryDirectory,
            siblings: siblings.map { FileAccessService.sameLocation($0, url) ? newURL : $0 }
                .sorted { SourceFormat.naturalOrder($0.lastPathComponent, $1.lastPathComponent) },
            needsParentAccess: needsParentAccess, isPartialDirectory: isPartialDirectory, revision: revision, archive: archive)
        result.fileLeases = fileLeases; return result
    }
}

/// 破損データや過大な展開から資源を守る上限。ソース累積量と一時ディスク量を分ける。
public struct ReaderLimits: Sendable {
    public var entryCount = 100_000
    public var imageBytes: Int64 = 256 * 1024 * 1024
    public var imagePixels: Int64 = 100_000_000
    public var sourceBytes: Int64 = 10 * 1024 * 1024 * 1024
    public var temporaryBytes: Int64 = 2 * 1024 * 1024 * 1024
    public init() {}
}

/// 各処理のエラーを、画面に表示できる日本語メッセージへまとめる。
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
        case .sourceChanged: "ファイルが外部で変更されています。もう一度開いてください。"
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
    // 数字を自然順で比較し、同値ならUTF-8順で揃えて並びを安定させる。
    public static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        return comparison == .orderedSame ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : comparison == .orderedAscending
    }
}
