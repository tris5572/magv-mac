import Foundation

/// ディスクから画像が削除されても寸法情報は残し、必要な画像だけを展開・利用中だけ保持する。
public actor ArchiveImageStore {
    private struct Known { let metadata: ImageMetadata?; let failure: String?; let fileID: UUID }
    private struct Pending {
        let id: UUID; let task: Task<PreparedArchiveImage, Error>
        var consumers: Set<UUID>; var speculative: Bool
    }
    private var url: URL
    private let index: ArchiveIndex
    private let directory: TemporaryDirectory
    private let access: FileAccessLease
    private let worker: ArchiveExtractionWorker
    nonisolated let initialEntries: [ImageEntry]
    // 確認済みの寸法・失敗情報と、進行中の展開を別々に保持する。
    private var known: [Int: Known] = [:]
    private var pending: [Int: Pending] = [:]

    init(url: URL, index: ArchiveIndex, directory: TemporaryDirectory, access: FileAccessLease, limits: ReaderLimits) {
        self.url = url; self.index = index; self.directory = directory; self.access = access
        initialEntries = index.members.map { member in
            ImageEntry(id: "\(member.ordinal):\(member.path)", name: member.path,
                fileURL: directory.url.appendingPathComponent(UUID().uuidString).appendingPathExtension((member.path as NSString).pathExtension))
        }
        worker = ArchiveExtractionWorker(url: url, index: index, directory: directory, limits: limits)
    }

    /// 寸法だけの要求では既知情報を使い、ファイルが必要な要求では削除を防ぐリースを返す。
    func prepare(_ indices: [Int], files: Bool, speculative: Bool) async throws -> (images: [ImageEntry], leases: [ExtractionFileLease]) {
        try Task.checkCancellation()
        guard try FileRevision.read(url) == index.revision else { throw ReaderError.sourceChanged }
        var leases: [ExtractionFileLease] = []
        for index in Set(indices).sorted() where initialEntries.indices.contains(index) {
            try Task.checkCancellation()
            if !files && known[index] != nil { continue }
            if let state = known[index] {
                if state.failure != nil { continue }
                if let file = directory.file(state.fileID, speculative: speculative) { leases.append(file); continue }
            }
            let file = try await materialize(index, speculative: speculative)
            if files { leases.append(file) }
        }
        try Task.checkCancellation()
        var result = initialEntries
        for (index, state) in known { result[index].metadata = state.metadata; result[index].failure = state.failure }
        return (result, leases)
    }
    // 同じ画像の同時要求は1つの展開タスクを共有する。表示要求が加われば先読み扱いを解除する。
    private func materialize(_ index: Int, speculative: Bool) async throws -> ExtractionFileLease {
        let consumer = UUID(); let work: Pending
        if var current = pending[index], !current.task.isCancelled {
            current.consumers.insert(consumer); current.speculative = current.speculative && speculative
            pending[index] = current; work = current
        } else {
            let member = self.index.members[index]; let output = initialEntries[index].fileURL
            let task = Task.detached(priority: speculative ? .utility : .userInitiated) { [worker] in
                try await worker.extract(member, to: output, speculative: speculative)
            }
            work = Pending(id: UUID(), task: task, consumers: [consumer], speculative: speculative); pending[index] = work
        }
        do {
            let result = try await withTaskCancellationHandler { try await work.task.value } onCancel: {
                Task { await self.releaseConsumer(index, id: work.id, consumer: consumer) }
            }
            if pending[index]?.id == work.id {
                known[index] = Known(metadata: result.metadata, failure: result.failure, fileID: result.file.id)
                pending[index] = nil
            }
            try Task.checkCancellation()
            return directory.file(result.file.id, speculative: speculative) ?? result.file
        } catch {
            if pending[index]?.id == work.id { pending[index] = nil }
            throw error
        }
    }
    // 1つの要求がキャンセルされても、他の利用者が待っている展開は止めない。
    private func releaseConsumer(_ index: Int, id: UUID, consumer: UUID) {
        guard var work = pending[index], work.id == id else { return }
        work.consumers.remove(consumer)
        if work.consumers.isEmpty { work.task.cancel() }
        pending[index] = work
    }
    func cancelPrefetch() {
        for work in pending.values where work.speculative { work.task.cancel() }
    }
    func cancelAll() { for work in pending.values { work.task.cancel() } }
    func relocate(to url: URL) async {
        self.url = url
        for work in pending.values { work.task.cancel() }
        await worker.relocate(to: url)
    }
    public var extractionCount: Int { get async { await worker.extractionCount } }
}
