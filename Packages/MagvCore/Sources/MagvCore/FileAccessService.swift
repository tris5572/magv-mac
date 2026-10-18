import Foundation
import Darwin

/// デバイス・inode・サイズ・更新時刻を使い、同じパスへのファイル置換も検出する。
public struct FileRevision: Hashable, Sendable {
    private let device: Int32
    private let inode: UInt64
    private let size: Int64
    private let seconds: Int
    private let nanoseconds: Int

    public static func read(_ url: URL) throws -> FileRevision {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw FileAccessService.fileError(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReaderError.unsupported }
        return FileRevision(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

/// 生存期間に合わせてsecurity-scoped resourceのアクセス開始と終了を対にする。
public final class FileAccessLease: @unchecked Sendable {
    private let url: URL
    private let scoped: Bool
    public init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

/// ファイル列挙、許可範囲の判定、上書きを防ぐ名前変更を提供する。
public enum FileAccessService {
    public static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    // シンボリックリンクを解決し、文字列の前方一致ではなくパス要素で範囲を判定する。
    public static func contains(_ directory: URL, _ url: URL) -> Bool {
        let root = resolvedLocation(directory).pathComponents
        let path = resolvedLocation(url).pathComponents
        return path.starts(with: root)
    }

    private static func resolvedLocation(_ url: URL) -> URL {
        // 末尾が未作成だとFoundationが途中のリンクを解決しないため、存在する祖先から解決する。
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            suffix.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
    }

    /// 同じ親フォルダから、アーカイブ同士またはフォルダ同士の移動候補を自然順で返す。
    public static func siblings(of source: URL, kind: SourceKind) throws -> [URL] {
        do {
            var urls = try FileManager.default.contentsOfDirectory(at: source.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .filter { url in
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                          values.isSymbolicLink != true else { return false }
                    return kind == .archive
                        ? values.isRegularFile == true && SourceFormat.archiveExtensions.contains(url.pathExtension.lowercased())
                        : values.isDirectory == true
                }
            // 明示的に開いた、または名前変更で隠し項目になったソースも、移動時の現在位置として含める。
            if !urls.contains(where: { sameLocation($0, source) }),
               let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
               (kind == .archive ? values.isRegularFile == true : values.isDirectory == true) { urls.append(source) }
            // 名前変更で旧パスが消える前に、SourceLoaderと同じ正規化済みURLに揃える。
            return urls.map { $0.resolvingSymlinksInPath().standardizedFileURL }
                .sorted { SourceFormat.naturalOrder($0.lastPathComponent, $1.lastPathComponent) }
        } catch let error as CocoaError where error.code == .fileReadNoPermission { throw ReaderError.permission }
    }

    public static func validateBaseName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ReaderError.invalidName }
    }

    /// 同一フォルダ内で不可分に名前を変更し、他プロセスとの競合時も既存の宛先を上書きしない。
    public static func renameArchive(at source: URL, baseName: String, expectedRevision: FileRevision? = nil) throws -> URL {
        guard SourceFormat.archiveExtensions.contains(source.pathExtension.lowercased()) else { throw ReaderError.unsupported }
        try validateBaseName(baseName)
        if baseName == source.deletingPathExtension().lastPathComponent { return source }
        let revision = try FileRevision.read(source)
        if let expectedRevision, revision != expectedRevision { throw ReaderError.sourceChanged }
        var candidate = baseName
        while true {
            let destination = source.deletingLastPathComponent().appendingPathComponent(candidate).appendingPathExtension(source.pathExtension)
            if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            let code = errno
            // 別プロセスと競合しても上書きせず、末尾に「_」を足して再試行する。
            if code == EEXIST { candidate += "_"; continue }
            throw fileError(code)
        }
    }

    static func fileError(_ code: Int32) -> ReaderError {
        switch code {
        case EACCES, EPERM: .permission
        case ENOENT: .missing
        case ENAMETOOLONG: .rename("ファイル名が長すぎます。短い名前を入力してください。")
        case EROFS: .rename("保存先が読み取り専用です。")
        case ENOTSUP: .rename("このボリュームは上書きを防ぐ名前変更に対応していません。")
        default: .rename(String(cString: strerror(code)))
        }
    }

    /// 直下の通常画像だけを自然順で返す。隠しファイルとリンク先は列挙対象に含めない。
    public static func images(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true && SourceFormat.isImage($0.lastPathComponent)
            }
            .sorted { SourceFormat.naturalOrder($0.lastPathComponent, $1.lastPathComponent) }
    }
}
