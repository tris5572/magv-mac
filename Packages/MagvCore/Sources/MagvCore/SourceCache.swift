import Foundation

/// Cache keys cover both archive identity and the direct images of a directory.
private struct SourceFingerprint: Hashable, Sendable {
    let url: URL
    let files: [URL]
    let revisions: [FileRevision]
    static func read(_ selected: URL) throws -> Self {
        let access = FileAccessLease(url: selected)
        return try withExtendedLifetime(access) {
            let url = selected.resolvingSymlinksInPath().standardizedFileURL
            let info = try url.resourceValues(forKeys: [.isDirectoryKey])
            let files: [URL]
            if info.isDirectory == true { files = try FileAccessService.images(in: url) }
            else if SourceFormat.isImage(url.lastPathComponent) {
                files = (try? FileAccessService.images(in: url.deletingLastPathComponent())) ?? [url]
            } else { files = [url] }
            return Self(url: url, files: files, revisions: try files.map(FileRevision.read))
        }
    }
}

public actor SourceCache {
    private struct Value { let source: LoadedSource; var touched: UInt64; var prefetched: Bool }
    private struct Pending { let id: UUID; let task: Task<LoadedSource, Error>; var prefetched: Bool }
    private var values: [SourceFingerprint: Value] = [:]
    private var pending: [SourceFingerprint: Pending] = [:]
    private var clock: UInt64 = 0
    private let temporaryRoot: URL?
    private let storage: ExtractionStorage?
    private let countLimit: Int
    public init(temporaryRoot: URL? = nil, storage: ExtractionStorage? = nil, countLimit: Int = 3) {
        self.temporaryRoot = temporaryRoot; self.storage = storage; self.countLimit = max(1, countLimit)
    }
    public func load(_ url: URL, prefetch: Bool = false, initialIndex: Int = 0, mode: DisplayMode = .spread,
                     progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LoadedSource {
        let key = try await Task.detached(priority: prefetch ? .utility : .userInitiated) { try SourceFingerprint.read(url) }.value
        try Task.checkCancellation()
        if !prefetch { await cancelPrefetch(except: url); try Task.checkCancellation() }
        // A file replacement or directory edit invalidates the old extraction/list immediately.
        for old in values.keys where old.url == key.url && old != key { values[old] = nil }
        for old in pending.keys where old.url == key.url && old != key { pending.removeValue(forKey: old)?.task.cancel() }
        clock &+= 1
        if var value = values[key] {
            value.touched = clock; value.prefetched = value.prefetched && prefetch; values[key] = value
            progress("表示するページを準備中…")
            return try await prepare(value.source, at: initialIndex, mode: mode, prefetch: prefetch)
        }
        let work: Pending
        if var existing = pending[key] {
            existing.prefetched = existing.prefetched && prefetch; pending[key] = existing; work = existing
        } else {
            let root = temporaryRoot; let storage = storage
            let task = Task.detached(priority: prefetch ? .utility : .userInitiated) {
                try SourceLoader.load(url, temporaryRoot: root, storage: storage, progress: progress)
            }
            work = Pending(id: UUID(), task: task, prefetched: prefetch); pending[key] = work
        }
        do {
            let result = try await work.task.value
            if let current = pending[key], current.id == work.id {
                pending[key] = nil; clock &+= 1
                values[key] = Value(source: result.unpinned(), touched: clock, prefetched: current.prefetched)
                trim()
            }
            try Task.checkCancellation()
            progress("表示するページを準備中…")
            return try await prepare(result, at: initialIndex, mode: mode, prefetch: prefetch)
        } catch {
            if pending[key]?.id == work.id { pending[key] = nil }
            throw error
        }
    }
    private func prepare(_ source: LoadedSource, at index: Int, mode: DisplayMode, prefetch: Bool) async throws -> LoadedSource {
        let anchor = min(max(0, index), max(0, source.images.count - 1))
        return try await source.preparingPage(at: anchor, mode: mode, prefetch: prefetch)
    }
    private func trim() {
        while values.count > countLimit { if !evictOldest() { break } }
    }
    @discardableResult private func evictOldest() -> Bool {
        guard let oldest = values.min(by: {
                if $0.value.prefetched != $1.value.prefetched { return $0.value.prefetched }
                return $0.value.touched < $1.value.touched
            }) else { return false }
        values[oldest.key] = nil; return true
    }
    public func cancelPrefetch(except url: URL? = nil) async {
        let keep = url?.resolvingSymlinksInPath().standardizedFileURL
        for key in pending.keys where pending[key]?.prefetched == true && key.url != keep { pending.removeValue(forKey: key)?.task.cancel() }
        let archives = values.filter { $0.key.url != keep }.values.compactMap { $0.source.archive }
        for archive in archives { await archive.cancelPrefetch() }
    }
    public func cancelLoads(except url: URL? = nil) async {
        let keep = url?.resolvingSymlinksInPath().standardizedFileURL
        for key in pending.keys where key.url != keep { pending.removeValue(forKey: key)?.task.cancel() }
        let archives = values.filter { $0.key.url != keep }.values.compactMap { $0.source.archive }
        for archive in archives { await archive.cancelAll() }
    }
    public func relocate(_ source: LoadedSource, from oldURL: URL) async {
        await source.archive?.relocate(to: source.url)
        invalidate(oldURL); invalidate(source.url)
        guard let key = try? await Task.detached(operation: { try SourceFingerprint.read(source.url) }).value else { return }
        clock &+= 1; values[key] = Value(source: source.unpinned(), touched: clock, prefetched: false); trim()
    }
    public func removePrefetched() async {
        await cancelPrefetch()
        values = values.filter { !$0.value.prefetched }
    }
    public func invalidate(_ url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        for key in values.keys where key.url.path == path { values[key] = nil }
        for key in pending.keys where key.url.path == path { pending.removeValue(forKey: key)?.task.cancel() }
    }
    public func removeAll() async {
        let archives = values.values.compactMap { $0.source.archive }
        for archive in archives { await archive.cancelAll() }
        for work in pending.values { work.task.cancel() }
        pending.removeAll(); values.removeAll()
    }
    public var cachedCount: Int { values.count }
}
