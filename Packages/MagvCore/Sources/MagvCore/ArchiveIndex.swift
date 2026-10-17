import Foundation
import CArchive
import Darwin

public struct ArchiveMember: Sendable {
    public let ordinal: Int
    public let path: String
    public let declaredSize: Int64
}
public struct ArchiveIndex: Sendable {
    public let members: [ArchiveMember]
    public let revision: FileRevision
}

extension ArchiveReader {
    /// Enumerates headers without writing or decoding image payloads, including solid RAR5.
    public static func index(_ url: URL, limits: ReaderLimits = ReaderLimits(),
                             include: (String) -> Bool = isImagePath) throws -> ArchiveIndex {
        try withArchiveLocale {
            let revision = try FileRevision.read(url)
            let cursor = try ArchiveCursor(url: url, indexOnly: true)
            var members: [ArchiveMember] = []; var ordinal = 0; var declaredBytes: Int64 = 0
            while let entry = try cursor.next(limits: limits, ordinal: ordinal) {
                if entry.regular && include(entry.path) {
                    guard entry.size <= limits.imageBytes else { throw ReaderError.limit("単一画像の展開量") }
                    let size = max(0, entry.size)
                    guard size <= limits.sourceBytes - declaredBytes else { throw ReaderError.limit("ソース累積展開量") }
                    declaredBytes += size
                    members.append(ArchiveMember(ordinal: ordinal, path: entry.path, declaredSize: entry.size))
                }
                try cursor.skip(); ordinal += 1
            }
            guard try FileRevision.read(url) == revision else { throw ReaderError.sourceChanged }
            members.sort {
                if $0.path == $1.path { return $0.ordinal < $1.ordinal }
                return SourceFormat.naturalOrder($0.path, $1.path)
            }
            return ArchiveIndex(members: members, revision: revision)
        }
    }
}

// Cursor calls run synchronously inside a worker actor. A reader never crosses simultaneous tasks.
final class ArchiveCursor {
    struct Header { let path: String; let size: Int64; let regular: Bool }
    let reader: OpaquePointer
    init(url: URL, indexOnly: Bool = false) throws {
        guard let reader = archive_read_new() else { throw ReaderError.archive("メモリを確保できません。") }
        archive_read_support_filter_none(reader)
        archive_read_support_format_zip_seekable(reader)
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
        archive_read_set_format_option(reader, "zip", "hdrcharset", "CP932")
        if indexOnly && archive_read_set_format_option(reader, "rar5", "magv-index-only", "1") != ARCHIVE_OK {
            archive_read_free(reader); throw ReaderError.archive("一覧取得用の展開器を初期化できません。")
        }
        guard archive_read_open_filename(reader, url.path, 64 * 1024) == ARCHIVE_OK else {
            let failure = ArchiveReader.error(reader); archive_read_free(reader); throw failure
        }
        self.reader = reader
    }
    deinit { archive_read_free(reader) }
    var needsSolidDictionary: Bool { archive_format(reader) == ARCHIVE_FORMAT_RAR_V5 }
    func next(limits: ReaderLimits, ordinal: Int) throws -> Header? {
        try Task.checkCancellation()
        var entry: OpaquePointer?
        let status = archive_read_next_header(reader, &entry)
        if status == ARCHIVE_EOF { return nil }
        guard status >= ARCHIVE_OK, let entry else { throw ArchiveReader.error(reader) }
        guard ordinal < limits.entryCount else { throw ReaderError.limit("エントリ数") }
        if archive_entry_is_encrypted(entry) > 0 { throw ReaderError.encrypted }
        guard let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry) else { throw ReaderError.archive("ファイル名を解釈できません。") }
        let path = String(cString: raw)
        guard ArchiveReader.isSafePath(path) else { throw ReaderError.unsafePath(path) }
        return Header(path: path, size: archive_entry_size(entry), regular: archive_entry_filetype(entry) == S_IFREG && archive_entry_symlink(entry) == nil && archive_entry_hardlink(entry) == nil)
    }
    func skip() throws { guard archive_read_data_skip(reader) >= ARCHIVE_OK else { throw ArchiveReader.error(reader) } }
}

func withArchiveLocale<T>(_ operation: () throws -> T) throws -> T {
    guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { throw ReaderError.archive("UTF-8のファイル名変換を初期化できません。") }
    let previous = uselocale(locale)
    defer { uselocale(previous); freelocale(locale) }
    return try operation()
}

struct PreparedArchiveImage: Sendable {
    let metadata: ImageMetadata?
    let failure: String?
    let file: ExtractionFileLease
}

/// Keeps a forward cursor for solid streams; backward cache misses reopen the stream.
actor ArchiveExtractionWorker {
    private var url: URL
    private let index: ArchiveIndex
    private let directory: TemporaryDirectory
    private let limits: ReaderLimits
    private let progress: @Sendable (Int64) -> Void
    private var cursor: ArchiveCursor?
    private var nextOrdinal = 0
    private var expanded: [Int: Int64] = [:]
    private var totalExpanded: Int64 = 0
    private(set) var extractionCount = 0
    init(url: URL, index: ArchiveIndex, directory: TemporaryDirectory, limits: ReaderLimits,
         progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.url = url; self.index = index; self.directory = directory; self.limits = limits; self.progress = progress
    }
    func relocate(to url: URL) { self.url = url; cursor = nil; nextOrdinal = 0 }
    func extract(_ member: ArchiveMember, to output: URL, speculative: Bool) throws -> PreparedArchiveImage {
        try withArchiveLocale {
            try Task.checkCancellation()
            guard try FileRevision.read(url) == index.revision else { throw ReaderError.sourceChanged }
            do {
                if cursor == nil || member.ordinal < nextOrdinal { cursor = try ArchiveCursor(url: url); nextOrdinal = 0 }
                guard let cursor else { throw ReaderError.archive("展開器を初期化できません。") }
                while let header = try cursor.next(limits: limits, ordinal: nextOrdinal) {
                    let ordinal = nextOrdinal; nextOrdinal += 1
                    if ordinal == member.ordinal {
                        guard header.regular, header.path == member.path, header.size == member.declaredSize else { throw ReaderError.sourceChanged }
                        let file = try directory.createFile(at: output, speculative: speculative)
                        let handle = try FileHandle(forWritingTo: output)
                        do { try drain(cursor, ordinal: ordinal, image: true, file: file, handle: handle); try handle.close() }
                        catch { try? handle.close(); throw error }
                        try Task.checkCancellation()
                        guard try FileRevision.read(url) == index.revision else { throw ReaderError.sourceChanged }
                        var metadata: ImageMetadata?; var failure: String?
                        do { metadata = try ImageDecoder.metadata(at: output, limits: limits) }
                        catch let error as ReaderError {
                            if case .limit = error { throw error }
                            failure = error.localizedDescription
                        } catch { failure = error.localizedDescription }
                        file.seal(); extractionCount += 1
                        return PreparedArchiveImage(metadata: metadata, failure: failure, file: file)
                    }
                    // ZIP and non-solid RAR4 skip payloads; RAR5 preserves solid dictionary state.
                    if !cursor.needsSolidDictionary { try cursor.skip() }
                    else { try drain(cursor, ordinal: ordinal, image: ArchiveReader.isImagePath(header.path), file: nil, handle: nil) }
                }
                throw ReaderError.sourceChanged
            } catch { cursor = nil; nextOrdinal = 0; throw error }
        }
    }
    private func drain(_ cursor: ArchiveCursor, ordinal: Int, image: Bool, file: ExtractionFileLease?, handle: FileHandle?) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024); var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let size = archive_read_data(cursor.reader, &buffer, buffer.count)
            guard size >= 0 else { throw ArchiveReader.error(cursor.reader) }
            if size == 0 { return }
            count += Int64(size)
            guard !image || count <= limits.imageBytes else { throw ReaderError.limit("単一画像の展開量") }
            let additional = max(0, count - (expanded[ordinal] ?? 0))
            guard additional <= limits.sourceBytes - totalExpanded else { throw ReaderError.limit("ソース累積展開量") }
            totalExpanded += additional; expanded[ordinal] = max(count, expanded[ordinal] ?? 0)
            if let file {
                guard count <= limits.temporaryBytes else { throw ReaderError.limit("一時ディスクキャッシュ2GiB") }
                try file.reserve(Int64(size)); try handle!.write(contentsOf: Data(buffer.prefix(size)))
                progress(count)
            }
        }
    }
}
