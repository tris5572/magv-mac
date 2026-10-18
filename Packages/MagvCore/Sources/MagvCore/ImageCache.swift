import Foundation

/// rawValueが大きい用途ほど優先する。通常表示をルーペや先読みより先にデコードする。
public enum ImageUse: Int, Sendable { case prefetch, loupe, display }

/// 1つのデコーダーで表示要求を先読みより優先し、同じキーへの要求は処理を共有する。
public actor ImageCache {
    // 更新情報と要求解像度もキーに含め、変更前の画像や別サイズの結果と混同しない。
    private struct Key: Hashable, Sendable { let url: URL; let revision: FileRevision; let pixels: Int; let highResolution: Bool }
    private struct Value { let image: DecodedImage; var touched: UInt64; var use: ImageUse }
    private struct Waiter {
        let continuation: CheckedContinuation<DecodedImage, Error>
        let owner: LoadedSource?
        let use: ImageUse
    }
    private struct Pending {
        let id: UUID; let order: UInt64
        var waiters: [UUID: Waiter]
        var use: ImageUse { waiters.values.max { $0.use.rawValue < $1.use.rawValue }?.use ?? .prefetch }
    }
    private var values: [Key: Value] = [:]
    private var pending: [Key: Pending] = [:]
    private var active: UUID?
    private var clock: UInt64 = 0
    private var bytes = 0
    private var highResolutionBytes = 0
    private let capacity: Int
    private let loupeCapacity: Int
    typealias Decode = @Sendable (URL, Int, Int) throws -> DecodedImage
    private let decode: Decode
    public init(capacity: Int = 256 * 1024 * 1024, loupeCapacity: Int = 64 * 1024 * 1024) {
        self.capacity = max(0, capacity); self.loupeCapacity = min(max(0, capacity), max(0, loupeCapacity))
        decode = { try ImageDecoder.decode(at: $0, maxPixelSize: $1, maximumBytes: $2) }
    }
    init(decoder: @escaping Decode) {
        capacity = 256 * 1024 * 1024; loupeCapacity = 64 * 1024 * 1024; decode = decoder
    }

    /// 先読みの待機が途中でキャンセルされても、実際のデコード完了までは展開ファイルを保持する。
    public func image(at url: URL, maxPixelSize: Int, use: ImageUse = .display, retaining source: LoadedSource? = nil) async throws -> DecodedImage {
        try Task.checkCancellation()
        let key = Key(url: url.standardizedFileURL, revision: try FileRevision.read(url),
                      pixels: max(1, min(maxPixelSize, 8192)), highResolution: use == .loupe)
        clock &+= 1
        if var value = values[key] {
            value.touched = clock
            if use.rawValue > value.use.rawValue { value.use = use }
            values[key] = value
            return value.image
        }
        let consumer = UUID()
        let result: DecodedImage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(continuation: continuation, owner: source, use: use)
                if var work = pending[key] {
                    work.waiters[consumer] = waiter; pending[key] = work
                } else {
                    pending[key] = Pending(id: UUID(), order: clock, waiters: [consumer: waiter])
                }
                startNext()
            }
        } onCancel: {
            Task { await self.cancelWaiter(key, consumer: consumer) }
        }
        try Task.checkCancellation()
        return result
    }
    private func cancelWaiter(_ key: Key, consumer: UUID) {
        guard var work = pending[key], let waiter = work.waiters.removeValue(forKey: consumer) else { return }
        // Image I/Oの実行中デコードは中断できないため、ページ移動をまたいで共有可能に保つ。
        // 先読み要求の離脱後に表示要求が到着しても、同じ処理を利用できる。
        pending[key] = work.waiters.isEmpty && work.id != active ? nil : work
        waiter.continuation.resume(throwing: CancellationError())
    }

    // 実際のデコードは一度に1件。用途の優先度が同じなら要求の古いものから処理する。
    private func startNext() {
        guard active == nil, let next = pending.max(by: {
            if $0.value.use != $1.value.use { return $0.value.use.rawValue < $1.value.use.rawValue }
            return $0.value.order > $1.value.order
        }) else { return }
        let key = next.key; let id = next.value.id
        active = id
        let owners = next.value.waiters.values.compactMap(\.owner)
        Task.detached(priority: next.value.use == .prefetch ? .utility : .userInitiated) { [decode] in
            let result = withExtendedLifetime(owners) { Result {
                let image = try decode(key.url, key.pixels, key.highResolution ? 64 * 1024 * 1024 : 128 * 1024 * 1024)
                guard try FileRevision.read(key.url) == key.revision else { throw ReaderError.sourceChanged }
                return image
            } }
            await self.finish(key, id: id, result: result)
        }
    }
    // 有効な要求だけをキャッシュへ反映し、同じ画像を待つ全利用者へ結果を配る。
    private func finish(_ key: Key, id: UUID, result: Result<DecodedImage, Error>) {
        if active == id { active = nil }
        if let work = pending[key], work.id == id {
            pending[key] = nil
            if case .success(let image) = result {
                if image.byteCount <= capacity, !key.highResolution || image.byteCount <= loupeCapacity {
                    while key.highResolution && highResolutionBytes + image.byteCount > loupeCapacity,
                          let oldest = values.filter({ $0.key.highResolution }).min(by: { $0.value.touched < $1.value.touched }) {
                        remove(oldest.key)
                    }
                    // ルーペ用の上限に加え、通常表示とルーペを合わせた総量も上限内に収める。
                    while bytes + highResolutionBytes + image.byteCount > capacity,
                          let oldest = values.min(by: {
                            if $0.value.use == .prefetch && $1.value.use != .prefetch { return true }
                            if $1.value.use == .prefetch && $0.value.use != .prefetch { return false }
                            return $0.value.touched < $1.value.touched
                          }) { remove(oldest.key) }
                    clock &+= 1; values[key] = Value(image: image, touched: clock, use: work.use)
                    if key.highResolution { highResolutionBytes += image.byteCount } else { bytes += image.byteCount }
                }
            }
            for waiter in work.waiters.values { waiter.continuation.resume(with: result) }
        }
        startNext()
    }
    private func remove(_ key: Key) {
        guard let value = values.removeValue(forKey: key) else { return }
        if key.highResolution { highResolutionBytes -= value.image.byteCount } else { bytes -= value.image.byteCount }
    }
    public func cancelPrefetch() {
        cancelPrefetch(keepingActive: true)
    }
    private func cancelPrefetch(keepingActive: Bool) {
        for key in pending.keys where pending[key]?.use == .prefetch {
            guard var work = pending[key] else { continue }
            let waiters = work.waiters.values
            work.waiters.removeAll()
            pending[key] = keepingActive && work.id == active ? work : nil
            for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        }
    }
    /// 先読み・ルーペを優先して破棄し、深刻なメモリ不足では通常表示のキャッシュも解放する。
    public func memoryPressure(critical: Bool) {
        cancelPrefetch(keepingActive: false)
        for key in pending.keys where key.highResolution {
            if let work = pending.removeValue(forKey: key) { for waiter in work.waiters.values { waiter.continuation.resume(throwing: CancellationError()) } }
        }
        for key in values.keys where values[key]?.use == .prefetch { remove(key) }
        for key in values.keys where key.highResolution { remove(key) }
        if critical { for key in Array(values.keys) { remove(key) } }
    }
    public func removeAll() {
        for work in pending.values { for waiter in work.waiters.values { waiter.continuation.resume(throwing: CancellationError()) } }
        pending.removeAll(); values.removeAll(); bytes = 0; highResolutionBytes = 0
    }
    var isDecoding: Bool { active != nil }
    var pendingRequestCount: Int { pending.values.reduce(0) { $0 + $1.waiters.count } }
    public var byteCounts: (display: Int, loupe: Int) { (bytes, highResolutionBytes) }
}
