import Foundation
import CArchive
import Darwin

public struct ExtractedEntry: Sendable {
    public let path: String
    public let fileURL: URL
}

/// ZIP／RAR用の展開器だけを使う。出力名は生成し、アーカイブ内のパスを保存先に使わない。
public enum ArchiveReader {
    public static var version: String { String(cString: archive_version_string()) }

    /// 区切り文字を揃えて検証し、絶対パス・親への移動・ドライブ指定を拒否する。
    public static func isSafePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/") && !normalized.contains("\0")
            && !parts.contains("..") && !(parts.first?.contains(":") ?? false)
    }

    /// macOSの付随メタデータを除外し、対応画像だけを閲覧候補にする。
    public static func isImagePath(_ path: String) -> Bool {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return parts.first != "__MACOSX" && !parts.contains(where: { $0.hasPrefix("._") }) && SourceFormat.isImage(path)
    }

    /// 対象画像を全件展開する経路。通常閲覧の選択展開とは別に、テストや比較計測で使う。
    public static func extract(_ url: URL, into directory: URL, limits: ReaderLimits = ReaderLimits(),
                               include: (String) -> Bool = isImagePath,
                               reserveBytes: (Int64) throws -> Void = { _ in },
                               progress: @Sendable (Int) -> Void = { _ in }) throws -> [ExtractedEntry] {
        // libarchiveの名前変換に必要なロケールは呼び出しスレッドだけに設定し、プロセス全体は変更しない。
        guard let utf8Locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else {
            throw ReaderError.archive("UTF-8のファイル名変換を初期化できません。")
        }
        let oldLocale = uselocale(utf8Locale)
        defer { uselocale(oldLocale); freelocale(utf8Locale) }
        guard let reader = archive_read_new() else { throw ReaderError.archive("メモリを確保できません。") }
        defer { archive_read_free(reader) }
        archive_read_support_filter_none(reader)
        archive_read_support_format_zip(reader)
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
        // ZIPのUTF-8指定を優先し、指定のない旧来の日本語ZIPはCP932として解釈する。
        archive_read_set_format_option(reader, "zip", "hdrcharset", "CP932")
        guard archive_read_open_filename(reader, url.path, 64 * 1024) == ARCHIVE_OK else { throw error(reader) }

        var entry: OpaquePointer?
        var entries: [ExtractedEntry] = []
        var count = 0
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_OK, let entry else { throw error(reader) }
            count += 1
            guard count <= limits.entryCount else { throw ReaderError.limit("エントリ数") }
            if archive_entry_is_encrypted(entry) > 0 { throw ReaderError.encrypted }
            guard let rawPath = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry) else { throw ReaderError.archive("ファイル名を解釈できません。") }
            let path = String(cString: rawPath)
            guard isSafePath(path) else { throw ReaderError.unsafePath(path) }
            guard archive_entry_filetype(entry) == S_IFREG, archive_entry_symlink(entry) == nil,
                  archive_entry_hardlink(entry) == nil, include(path) else {
                guard archive_read_data_skip(reader) >= ARCHIVE_OK else { throw error(reader) }
                continue
            }
            guard archive_entry_size(entry) <= limits.imageBytes else { throw ReaderError.limit("単一画像の展開量") }
            let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension((path as NSString).pathExtension)
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw ReaderError.archive("一時ファイルを作成できません。") }
            let handle = try FileHandle(forWritingTo: output)
            do {
                var entryBytes: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let size = archive_read_data(reader, &buffer, buffer.count)
                    guard size >= 0 else { throw error(reader) }
                    if size == 0 { break }
                    // ヘッダーの申告サイズに加えて、実際の展開量も毎回検証する。
                    entryBytes += Int64(size)
                    totalBytes += Int64(size)
                    guard entryBytes <= limits.imageBytes else { throw ReaderError.limit("単一画像の展開量") }
                    guard totalBytes <= limits.sourceBytes else { throw ReaderError.limit("ソース累積展開量") }
                    guard totalBytes <= limits.temporaryBytes else { throw ReaderError.limit("一時ディスクキャッシュ2GiB") }
                    try reserveBytes(Int64(size))
                    try handle.write(contentsOf: Data(buffer.prefix(size)))
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            entries.append(ExtractedEntry(path: path, fileURL: output))
            progress(entries.count)
        }
        return entries.sorted { SourceFormat.naturalOrder($0.path, $1.path) }
    }

    // libarchiveの詳細エラーを、UIで扱える権限・暗号化・未対応形式などに変換する。
    static func error(_ reader: OpaquePointer) -> ReaderError {
        switch archive_errno(reader) {
        case EACCES, EPERM: return .permission
        case ENOENT: return .missing
        default: break
        }
        let detail = archive_error_string(reader).map { String(cString: $0) } ?? "不明な展開エラー"
        let lower = detail.lowercased()
        if lower.contains("encrypt") || lower.contains("passphrase") || lower.contains("password") { return .encrypted }
        if lower.contains("unsupported") || lower.contains("multi-volume") || lower.contains("multivolume") || lower.contains("split") {
            return .unsupportedCompression(detail)
        }
        return .archive(detail)
    }
}
