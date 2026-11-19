import Foundation
import Darwin

/// 全ソースの展開データを保持し、メモリと一時ディスクそれぞれの容量を管理する。
public final class ExtractionStorage: @unchecked Sendable {
    public static let defaultRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.tris.magv-native/Extraction", isDirectory: true)
    private static let registry = Registry()
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var stores: [URL: ExtractionStorage] = [:]
    }
    public static func shared(root: URL? = nil) throws -> ExtractionStorage {
        let root = (root ?? defaultRoot).standardizedFileURL
        registry.lock.lock(); defer { registry.lock.unlock() }
        if let existing = registry.stores[root] { return existing }
        let storage = try ExtractionStorage(root: root)
        registry.stores[root] = storage
        return storage
    }

    public let root: URL
    public let capacity: Int64
    public let memoryCapacity: Int64
    // このロックの下で容量・展開データ・保持数をまとめて更新する。
    private let lock = NSLock()
    private struct DirectoryRecord {
        var fd: Int32?
        var diskBytes: Int64 = 0
    }
    private var directories: [URL: DirectoryRecord] = [:]
    private var diskBytes: Int64 = 0
    private var memoryBytes: Int64 = 0
    private var isUnderMemoryPressure = false
    private struct FileRecord {
        let url: URL; let directory: URL
        let isInMemory: Bool
        var data: Data?
        var bytes: Int64 = 0; var pins = 1; var complete = false; var speculative: Bool
        var discardOnRelease = false
        var touched: UInt64
    }
    private var files: [UUID: FileRecord] = [:]
    private var clock: UInt64 = 0
    private static let marker = "magv-extraction-v1\n"

    public convenience init(root: URL, capacity: Int64 = 2 * 1024 * 1024 * 1024) throws {
        try self.init(root: root, capacity: capacity, memoryCapacity: 1024 * 1024 * 1024)
    }
    public init(root: URL, capacity: Int64 = 2 * 1024 * 1024 * 1024, memoryCapacity: Int64) throws {
        self.root = root.standardizedFileURL; self.capacity = max(0, capacity)
        self.memoryCapacity = max(0, memoryCapacity)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        Self.cleanOrphans(in: self.root)
    }
    public var byteCount: Int64 { lock.withLock { diskBytes } }
    public var memoryByteCount: Int64 { lock.withLock { memoryBytes } }

    fileprivate func create(onDisk: Bool) throws -> URL {
        try lock.withLock {
            let url = root.appendingPathComponent("magv-" + UUID().uuidString, isDirectory: true)
            let fd = onDisk ? try openDirectory(at: url) : nil
            directories[url] = DirectoryRecord(fd: fd)
            return url
        }
    }

    // ディスクが必要になった時点で、他プロセスからの清掃を防ぐ所有マーカーを作る。
    private func openDirectory(at url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let fd = Darwin.open(url.appendingPathComponent(".owner").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: url); throw ReaderError.archive("キャッシュを作成できません。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); try? FileManager.default.removeItem(at: url); throw ReaderError.archive("キャッシュをロックできません。")
        }
        let data = Array(Self.marker.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            close(fd); try? FileManager.default.removeItem(at: url); throw ReaderError.archive("キャッシュを作成できません。")
        }
        return fd
    }
    fileprivate func reserve(_ amount: Int64, for url: URL) throws {
        try lock.withLock {
            guard directories[url] != nil else { throw CancellationError() }
            try reserveDisk(amount)
            directories[url]!.diskBytes += amount
        }
    }
    fileprivate func release(_ url: URL) {
        lock.withLock {
            guard let directory = directories.removeValue(forKey: url) else { return }
            removeDirectory(at: url, fd: directory.fd)
            diskBytes -= directory.diskBytes
            for id in files.keys where files[id]?.directory == url {
                if let record = files.removeValue(forKey: id), record.isInMemory { memoryBytes -= record.bytes }
            }
        }
    }
    private func removeDirectory(at url: URL, fd: Int32?) {
        guard let fd else { return }
        try? FileManager.default.removeItem(at: url)
        close(fd)
    }
    /// すべての読み込みへキャンセルを要求した後、プロセス終了時だけ呼び出す。
    public func cleanOwnedAtExit() {
        lock.withLock {
            for (url, directory) in directories { removeDirectory(at: url, fd: directory.fd) }
            files.removeAll(); directories.removeAll(); diskBytes = 0; memoryBytes = 0
            isUnderMemoryPressure = false
        }
    }
    private func reserveDisk(_ amount: Int64) throws {
        guard try makeRoom(for: amount, inMemory: false) else { throw ReaderError.limit("一時ディスクキャッシュ全体2GiB") }
        diskBytes += amount
    }
    // 使用中のデータは保護し、先読みと最終利用時刻を基準に空きを作る。
    private func makeRoom(for amount: Int64, inMemory: Bool) throws -> Bool {
        let limit = inMemory ? memoryCapacity : capacity
        guard amount >= 0, amount <= limit else { return false }
        let needed = amount - (limit - (inMemory ? memoryBytes : diskBytes))
        guard needed > 0 else { return true }
        let candidates = files.filter { $0.value.isInMemory == inMemory && $0.value.complete && $0.value.pins == 0 }
        guard candidates.values.reduce(Int64(0), { $0 + $1.bytes }) >= needed else { return false }
        var missing = needed
        for (id, record) in candidates.sorted(by: {
            if $0.value.speculative != $1.value.speculative { return $0.value.speculative }
            return $0.value.touched < $1.value.touched
        }) {
            try deleteFile(id)
            missing -= record.bytes
            if missing <= 0 { break }
        }
        return true
    }
    private func deleteFile(_ id: UUID) throws {
        guard let record = files[id] else { return }
        if record.isInMemory { memoryBytes -= record.bytes }
        else {
            if FileManager.default.fileExists(atPath: record.url.path) { try FileManager.default.removeItem(at: record.url) }
            diskBytes -= record.bytes
            directories[record.directory]!.diskBytes -= record.bytes
        }
        files[id] = nil
    }
    fileprivate func createFile(at url: URL, directory: TemporaryDirectory, speculative: Bool) throws -> ExtractionFileLease {
        try lock.withLock {
            guard let record = directories[directory.url] else { throw CancellationError() }
            if record.fd == nil { directories[directory.url]!.fd = try openDirectory(at: directory.url) }
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ReaderError.archive("一時ファイルを作成できません。") }
            return registerFile(at: url, directory: directory, inMemory: false, bytes: 0, speculative: speculative)
        }
    }
    fileprivate func createMemoryFile(at url: URL, directory: TemporaryDirectory, bytes: Int64,
                                      speculative: Bool) throws -> ExtractionFileLease? {
        try lock.withLock {
            guard directories[directory.url] != nil else { throw CancellationError() }
            guard !isUnderMemoryPressure, memoryCapacity > 0, try makeRoom(for: bytes, inMemory: true) else { return nil }
            memoryBytes += bytes
            return registerFile(at: url, directory: directory, inMemory: true, bytes: bytes, speculative: speculative)
        }
    }
    private func registerFile(at url: URL, directory: TemporaryDirectory, inMemory: Bool, bytes: Int64,
                              speculative: Bool) -> ExtractionFileLease {
        let id = UUID(); clock &+= 1
        files[id] = FileRecord(url: url, directory: directory.url, isInMemory: inMemory, bytes: bytes,
                               speculative: speculative, touched: clock)
        return ExtractionFileLease(id: id, url: url, isInMemory: inMemory, directory: directory, storage: self)
    }
    // リースの存続中は、完成済みデータを容量整理の対象から外す。
    fileprivate func pin(_ id: UUID, directory: TemporaryDirectory, speculative: Bool) -> ExtractionFileLease? {
        lock.withLock {
            guard var record = files[id], record.complete else { return nil }
            if !record.isInMemory && !FileManager.default.fileExists(atPath: record.url.path) {
                try? deleteFile(id); return nil
            }
            clock &+= 1; record.touched = clock; record.pins += 1
            record.speculative = record.speculative && speculative; files[id] = record
            return ExtractionFileLease(id: id, url: record.url, isInMemory: record.isInMemory, directory: directory, storage: self)
        }
    }
    fileprivate func reserve(_ amount: Int64, file: UUID) throws {
        try lock.withLock {
            guard let directory = files[file]?.directory else { throw CancellationError() }
            try reserveDisk(amount)
            files[file]!.bytes += amount; directories[directory]!.diskBytes += amount
        }
    }
    fileprivate func reserveMemory(to amount: Int64, file: UUID) throws -> Bool {
        try lock.withLock {
            guard let record = files[file] else { throw CancellationError() }
            let additional = amount - record.bytes
            if additional <= 0 { return true }
            guard !isUnderMemoryPressure, try makeRoom(for: additional, inMemory: true) else { return false }
            files[file]!.bytes = amount; memoryBytes += additional
            return true
        }
    }
    fileprivate func data(for id: UUID) -> Data? { lock.withLock { files[id]?.data } }
    fileprivate func seal(_ id: UUID, data: Data?) throws {
        try lock.withLock {
            guard let record = files[id] else { throw CancellationError() }
            if let data {
                memoryBytes -= record.bytes - Int64(data.count)
                files[id]!.bytes = Int64(data.count)
                files[id]!.data = data
            }
            files[id]!.complete = true
        }
    }
    fileprivate func unpin(_ id: UUID) {
        lock.withLock {
            guard files[id] != nil else { return }
            files[id]!.pins -= 1
            if files[id]!.pins == 0 && (!files[id]!.complete || files[id]!.discardOnRelease) { try? deleteFile(id) }
        }
    }
    public func trimFiles(prefetchedOnly: Bool = false) {
        lock.withLock {
            for (id, record) in files where !prefetchedOnly || record.speculative {
                if record.pins == 0 { try? deleteFile(id) }
                else if record.isInMemory { files[id]!.discardOnRelease = true }
            }
        }
    }
    /// 圧迫中は新しいページの展開にディスクを使う。
    public func setMemoryPressure(_ active: Bool) { lock.withLock { isUnderMemoryPressure = active } }
    public var cachedFileCount: Int { lock.withLock { files.count } }
    /// 専用の名前・マーカー・取得可能なロックを確認し、異常終了で残った領域だけを清掃する。
    public static func cleanOrphans(in root: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix("magv-"), UUID(uuidString: String(name.dropFirst(5))) != nil,
                  let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true else { continue }
            let fd = Darwin.open(url.appendingPathComponent(".owner").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(fd, LOCK_UN) }
            var data = [UInt8](repeating: 0, count: marker.utf8.count)
            let size = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard size == data.count, String(bytes: data, encoding: .utf8) == marker else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// ソースごとの展開領域。最後の参照がなくなると保存データと容量予約を解放する。
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL
    private let storage: ExtractionStorage
    public convenience init(root: URL? = nil) throws { try self.init(storage: ExtractionStorage.shared(root: root)) }
    public convenience init(storage: ExtractionStorage) throws { try self.init(storage: storage, createOnDisk: true) }
    init(storage: ExtractionStorage, createOnDisk: Bool) throws {
        self.storage = storage
        url = try storage.create(onDisk: createOnDisk)
    }
    public func reserve(_ amount: Int64) throws { try storage.reserve(amount, for: url) }
    func createFile(at url: URL, speculative: Bool) throws -> ExtractionFileLease {
        try storage.createFile(at: url, directory: self, speculative: speculative)
    }
    func createMemoryFile(at url: URL, bytes: Int64, speculative: Bool) throws -> ExtractionFileLease? {
        try storage.createMemoryFile(at: url, directory: self, bytes: bytes, speculative: speculative)
    }
    func file(_ id: UUID, speculative: Bool) -> ExtractionFileLease? { storage.pin(id, directory: self, speculative: speculative) }
    deinit { storage.release(url) }
}

/// 表示ページやデコーダーが展開済みデータを容量整理から保護する。
public final class ExtractionFileLease: @unchecked Sendable {
    let id: UUID
    public let url: URL
    let isInMemory: Bool
    private let directory: TemporaryDirectory
    private let storage: ExtractionStorage
    fileprivate init(id: UUID, url: URL, isInMemory: Bool, directory: TemporaryDirectory, storage: ExtractionStorage) {
        self.id = id; self.url = url; self.isInMemory = isInMemory; self.directory = directory; self.storage = storage
    }
    var data: Data? { storage.data(for: id) }
    func reserve(_ bytes: Int64) throws { try storage.reserve(bytes, file: id) }
    func reserveMemory(to bytes: Int64) throws -> Bool { try storage.reserveMemory(to: bytes, file: id) }
    func seal(data: Data? = nil) throws { try storage.seal(id, data: data) }
    deinit { storage.unpin(id) }
}
