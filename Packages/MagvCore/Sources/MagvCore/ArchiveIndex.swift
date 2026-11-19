import Foundation
import CArchive
import Darwin

/// アーカイブ内の画像位置。パスが重複しても、ヘッダーの出現順 ordinal で識別する。
public struct ArchiveMember: Sendable {
    public let ordinal: Int
    public let path: String
    public let declaredSize: Int64
}
/// 自然順の画像一覧と、一覧取得時点のファイル更新情報。
public struct ArchiveIndex: Sendable {
    public let members: [ArchiveMember]
    public let revision: FileRevision
}

extension ArchiveReader {
    /// ソリッドRAR5を含め、画像本体を書き出したりデコードしたりせずヘッダーを列挙する。
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

// カーソル操作はワーカーアクター内で同期実行し、同じ展開器を複数タスクから同時操作しない。
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
        // 同梱パッチの一覧専用モードでは、ソリッドRAR5も画像本体を展開せず列挙する。
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

/// ファイル名変換用のロケールを呼び出しスレッドだけに設定し、処理後に元へ戻す。
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

/// ソリッド圧縮の展開位置を前向きに保持し、過去の未キャッシュ画像は先頭から開き直す。
actor ArchiveExtractionWorker {
    private var url: URL
    private let index: ArchiveIndex
    private let directory: TemporaryDirectory
    private let limits: ReaderLimits
    private let prefersMemory: Bool
    private let progress: @Sendable (Int64) -> Void
    private var cursor: ArchiveCursor?
    private var nextOrdinal = 0
    private var expanded: [Int: Int64] = [:]
    private var totalExpanded: Int64 = 0
    private(set) var extractionCount = 0
    init(url: URL, index: ArchiveIndex, directory: TemporaryDirectory, limits: ReaderLimits,
         prefersMemory: Bool,
         progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.url = url; self.index = index; self.directory = directory; self.limits = limits; self.progress = progress
        self.prefersMemory = prefersMemory
    }
    func relocate(to url: URL) { self.url = url; cursor = nil; nextOrdinal = 0 }
    func extract(_ member: ArchiveMember, to output: URL, speculative: Bool) throws -> PreparedArchiveImage {
        try withArchiveLocale {
            try Task.checkCancellation()
            guard try FileRevision.read(url) == index.revision else { throw ReaderError.sourceChanged }
            do {
                // 前方は現在の展開位置から続行できる。通過済みの画像は先頭から読み直す。
                if cursor == nil || member.ordinal < nextOrdinal { cursor = try ArchiveCursor(url: url); nextOrdinal = 0 }
                guard let cursor else { throw ReaderError.archive("展開器を初期化できません。") }
                while let header = try cursor.next(limits: limits, ordinal: nextOrdinal) {
                    let ordinal = nextOrdinal; nextOrdinal += 1
                    if ordinal == member.ordinal {
                        guard header.regular, header.path == member.path, header.size == member.declaredSize else { throw ReaderError.sourceChanged }
                        return try readImage(cursor, member: member, output: output, speculative: speculative)
                    }
                    // ZIPと非ソリッドRAR4は本体をスキップし、RAR5は読み進めてソリッド圧縮の辞書状態を維持する。
                    if !cursor.needsSolidDictionary { try cursor.skip() }
                    else { try drain(cursor, ordinal: ordinal, image: ArchiveReader.isImagePath(header.path)) }
                }
                throw ReaderError.sourceChanged
            } catch { cursor = nil; nextOrdinal = 0; throw error }
        }
    }
    private func readImage(_ cursor: ArchiveCursor, member: ArchiveMember, output: URL,
                           speculative: Bool) throws -> PreparedArchiveImage {
        let declared = max(0, member.declaredSize)
        var memory = prefersMemory ? try directory.createMemoryFile(at: output, bytes: declared, speculative: speculative) : nil
        var data = Data()
        if memory != nil { data.reserveCapacity(Int(declared)) }
        func openDisk() throws -> (file: ExtractionFileLease, handle: FileHandle) {
            let file = try directory.createFile(at: output, speculative: speculative)
            return (file, try FileHandle(forWritingTo: output))
        }
        var disk = memory == nil ? try openDisk() : nil
        do {
            try drain(cursor, ordinal: member.ordinal, image: true) { chunk, expandedBytes in
                if let memory, try memory.reserveMemory(to: expandedBytes) {
                    data.append(chunk.bindMemory(to: UInt8.self))
                } else {
                    guard expandedBytes <= limits.temporaryBytes else { throw ReaderError.limit("一時ディスクキャッシュ2GiB") }
                    let destination = try disk ?? openDisk()
                    // 宣言サイズを超えても、展開位置を保ったままディスクへ移す。
                    if disk == nil {
                        disk = destination
                        try destination.file.reserve(Int64(data.count))
                        try destination.handle.write(contentsOf: data)
                        data = Data()
                        memory = nil
                    }
                    try destination.file.reserve(Int64(chunk.count))
                    try destination.handle.write(contentsOf: Data(chunk))
                }
                progress(expandedBytes)
            }
            try disk?.handle.close()
        } catch {
            try? disk?.handle.close()
            throw error
        }
        try Task.checkCancellation()
        guard try FileRevision.read(url) == index.revision else { throw ReaderError.sourceChanged }

        let input = ImageInput(url: output, data: memory == nil ? nil : data)
        var metadata: ImageMetadata?; var failure: String?
        do { metadata = try ImageDecoder.metadata(input, limits: limits) }
        catch let error as ReaderError {
            if case .limit = error { throw error }
            failure = error.localizedDescription
        } catch { failure = error.localizedDescription }
        try Task.checkCancellation()
        guard let file = memory ?? disk?.file else { throw ReaderError.archive("画像の展開先を初期化できません。") }
        try file.seal(data: input.data)
        extractionCount += 1
        return PreparedArchiveImage(metadata: metadata, failure: failure, file: file)
    }

    private func drain(_ cursor: ArchiveCursor, ordinal: Int, image: Bool,
                       write: (UnsafeRawBufferPointer, Int64) throws -> Void = { _, _ in }) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024); var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let size = archive_read_data(cursor.reader, &buffer, buffer.count)
            guard size >= 0 else { throw ArchiveReader.error(cursor.reader) }
            if size == 0 { return }
            count += Int64(size)
            guard !image || count <= limits.imageBytes else { throw ReaderError.limit("単一画像の展開量") }
            // 同じエントリを読み直しても累積展開量を二重計上しない。実測した最大量だけを加算する。
            let additional = max(0, count - (expanded[ordinal] ?? 0))
            guard additional <= limits.sourceBytes - totalExpanded else { throw ReaderError.limit("ソース累積展開量") }
            totalExpanded += additional; expanded[ordinal] = max(count, expanded[ordinal] ?? 0)
            try buffer.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[..<size]), count) }
        }
    }
}
