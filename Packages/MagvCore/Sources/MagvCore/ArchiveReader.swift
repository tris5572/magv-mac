import Foundation
import CArchive
import Darwin

public struct ExtractedEntry: Sendable {
    public let path: String
    public let fileURL: URL
}

/// Uses only ZIP/RAR readers. Payloads are streamed to generated names, never archive paths.
public enum ArchiveReader {
    public static var version: String { String(cString: archive_version_string()) }

    public static func isSafePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/") && !normalized.contains("\0")
            && !parts.contains("..") && !(parts.first?.contains(":") ?? false)
    }

    public static func isImagePath(_ path: String) -> Bool {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        return parts.first != "__MACOSX" && !parts.contains(where: { $0.hasPrefix("._") }) && SourceFormat.isImage(path)
    }

    public static func extract(_ url: URL, into directory: URL, limits: ReaderLimits = ReaderLimits(),
                               include: (String) -> Bool = isImagePath,
                               progress: @Sendable (Int) -> Void = { _ in }) throws -> [ExtractedEntry] {
        // libarchive converts names using the calling thread's locale. Do not change the process locale.
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
        // UTF-8 ZIP flags take precedence; legacy Japanese ZIPs commonly use CP932.
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
                    entryBytes += Int64(size)
                    totalBytes += Int64(size)
                    guard entryBytes <= limits.imageBytes else { throw ReaderError.limit("単一画像の展開量") }
                    guard totalBytes <= limits.sourceBytes else { throw ReaderError.limit("ソース累積展開量") }
                    guard totalBytes <= limits.temporaryBytes else { throw ReaderError.limit("一時ディスクキャッシュ2GiB") }
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

    private static func error(_ reader: OpaquePointer) -> ReaderError {
        let detail = archive_error_string(reader).map { String(cString: $0) } ?? "不明な展開エラー"
        let lower = detail.lowercased()
        if lower.contains("encrypt") || lower.contains("passphrase") || lower.contains("password") { return .encrypted }
        if lower.contains("unsupported") || lower.contains("multi-volume") || lower.contains("multivolume") || lower.contains("split") {
            return .unsupportedCompression(detail)
        }
        return .archive(detail)
    }
}
