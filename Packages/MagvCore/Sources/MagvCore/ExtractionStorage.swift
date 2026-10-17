import Foundation
import Darwin

/// One byte budget for every live extraction, including sources still displayed during a switch.
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
    private let lock = NSLock()
    private var allocations: [URL: Int64] = [:]
    private var bytes: Int64 = 0
    private struct FileRecord {
        let url: URL; let directory: URL
        var bytes: Int64 = 0; var pins = 1; var complete = false; var speculative: Bool
        var touched: UInt64
    }
    private var files: [UUID: FileRecord] = [:]
    private var clock: UInt64 = 0
    private static let marker = "magv-extraction-v1\n"

    public init(root: URL, capacity: Int64 = 2 * 1024 * 1024 * 1024) throws {
        self.root = root.standardizedFileURL; self.capacity = max(0, capacity)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        Self.cleanOrphans(in: self.root)
    }
    public var byteCount: Int64 { lock.withLock { bytes } }

    fileprivate func create() throws -> (URL, Int32) {
        try lock.withLock {
            let url = root.appendingPathComponent("magv-" + UUID().uuidString, isDirectory: true)
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
            allocations[url] = 0
            return (url, fd)
        }
    }
    fileprivate func reserve(_ amount: Int64, for url: URL) throws {
        try lock.withLock {
            guard allocations[url] != nil else { throw CancellationError() }
            try makeRoom(amount)
            allocations[url, default: 0] += amount; bytes += amount
        }
    }
    fileprivate func release(_ url: URL, fd: Int32) {
        lock.withLock {
            // Keep the process lock until removal finishes so a second instance cannot clean a live source.
            try? FileManager.default.removeItem(at: url)
            files = files.filter { $0.value.directory != url }
            bytes -= allocations.removeValue(forKey: url) ?? 0
            flock(fd, LOCK_UN); close(fd)
        }
    }
    /// Called only at process exit, after cancelling all readers.
    public func cleanOwnedAtExit() {
        lock.withLock {
            for url in allocations.keys { try? FileManager.default.removeItem(at: url) }
            files.removeAll(); allocations.removeAll(); bytes = 0
        }
    }
    private func makeRoom(_ amount: Int64) throws {
        guard amount >= 0, amount <= capacity else { throw ReaderError.limit("一時ディスクキャッシュ全体2GiB") }
        while amount > capacity - bytes {
            guard let victim = files.filter({ $0.value.complete && $0.value.pins == 0 }).min(by: {
                if $0.value.speculative != $1.value.speculative { return $0.value.speculative }
                return $0.value.touched < $1.value.touched
            }) else { throw ReaderError.limit("一時ディスクキャッシュ全体2GiB") }
            try deleteFile(victim.key)
        }
    }
    private func deleteFile(_ id: UUID) throws {
        guard let record = files[id] else { return }
        if FileManager.default.fileExists(atPath: record.url.path) { try FileManager.default.removeItem(at: record.url) }
        files[id] = nil; bytes -= record.bytes
        if allocations[record.directory] != nil { allocations[record.directory, default: 0] -= record.bytes }
    }
    fileprivate func createFile(at url: URL, directory: TemporaryDirectory, speculative: Bool) throws -> ExtractionFileLease {
        try lock.withLock {
            guard allocations[directory.url] != nil else { throw CancellationError() }
            let id = UUID(); clock &+= 1
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ReaderError.archive("一時ファイルを作成できません。") }
            files[id] = FileRecord(url: url, directory: directory.url, speculative: speculative, touched: clock)
            return ExtractionFileLease(id: id, url: url, directory: directory, storage: self)
        }
    }
    fileprivate func pin(_ id: UUID, directory: TemporaryDirectory, speculative: Bool) -> ExtractionFileLease? {
        lock.withLock {
            guard var record = files[id], record.complete else { return nil }
            guard FileManager.default.fileExists(atPath: record.url.path) else { try? deleteFile(id); return nil }
            clock &+= 1; record.touched = clock; record.pins += 1
            record.speculative = record.speculative && speculative; files[id] = record
            return ExtractionFileLease(id: id, url: record.url, directory: directory, storage: self)
        }
    }
    fileprivate func reserve(_ amount: Int64, file: UUID) throws {
        try lock.withLock {
            guard let directory = files[file]?.directory else { throw CancellationError() }
            try makeRoom(amount)
            files[file]!.bytes += amount; allocations[directory, default: 0] += amount; bytes += amount
        }
    }
    fileprivate func seal(_ id: UUID) { lock.withLock { files[id]?.complete = true } }
    fileprivate func unpin(_ id: UUID) {
        lock.withLock {
            guard files[id] != nil else { return }
            files[id]!.pins -= 1
            if files[id]!.pins == 0 && !files[id]!.complete { try? deleteFile(id) }
        }
    }
    public func trimFiles(prefetchedOnly: Bool = false) {
        lock.withLock {
            for id in Array(files.keys) where files[id]!.pins == 0 && (!prefetchedOnly || files[id]!.speculative) { try? deleteFile(id) }
        }
    }
    public var cachedFileCount: Int { lock.withLock { files.count } }
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

public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL
    private let storage: ExtractionStorage
    private let fd: Int32
    public convenience init(root: URL? = nil) throws { try self.init(storage: ExtractionStorage.shared(root: root)) }
    public init(storage: ExtractionStorage) throws {
        self.storage = storage
        (url, fd) = try storage.create()
    }
    public func reserve(_ amount: Int64) throws { try storage.reserve(amount, for: url) }
    func createFile(at url: URL, speculative: Bool) throws -> ExtractionFileLease {
        try storage.createFile(at: url, directory: self, speculative: speculative)
    }
    func file(_ id: UUID, speculative: Bool) -> ExtractionFileLease? { storage.pin(id, directory: self, speculative: speculative) }
    deinit { storage.release(url, fd: fd) }
}

/// A displayed page or decoder pins its file; only unpinned files are eligible for disk LRU eviction.
public final class ExtractionFileLease: @unchecked Sendable {
    let id: UUID
    public let url: URL
    private let directory: TemporaryDirectory
    private let storage: ExtractionStorage
    fileprivate init(id: UUID, url: URL, directory: TemporaryDirectory, storage: ExtractionStorage) {
        self.id = id; self.url = url; self.directory = directory; self.storage = storage
    }
    func reserve(_ bytes: Int64) throws { try storage.reserve(bytes, file: id) }
    func seal() { storage.seal(id) }
    deinit { storage.unpin(id) }
}
