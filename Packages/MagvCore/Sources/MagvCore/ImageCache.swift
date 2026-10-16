import Foundation

public enum ImageUse: Int, Sendable { case prefetch, loupe, display }

/// A single decoder drains visible work before speculative work; all callers of a key share it.
public actor ImageCache {
    private struct Key: Hashable { let url: URL; let revision: FileRevision; let pixels: Int; let highResolution: Bool }
    private struct Value { let image: DecodedImage; var touched: UInt64; var use: ImageUse }
    private struct Pending {
        let id: UUID; let order: UInt64
        var use: ImageUse
        var waiters: [CheckedContinuation<DecodedImage, Error>]
    }
    private var values: [Key: Value] = [:]
    private var pending: [Key: Pending] = [:]
    private var active: UUID?
    private var clock: UInt64 = 0
    private var bytes = 0
    private var highResolutionBytes = 0
    private let capacity: Int
    private let loupeCapacity: Int
    public init(capacity: Int = 256 * 1024 * 1024, loupeCapacity: Int = 64 * 1024 * 1024) {
        self.capacity = max(0, capacity); self.loupeCapacity = min(max(0, capacity), max(0, loupeCapacity))
    }

    public func image(at url: URL, maxPixelSize: Int, use: ImageUse = .display) async throws -> DecodedImage {
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
        return try await withCheckedThrowingContinuation { continuation in
            if var work = pending[key] {
                work.waiters.append(continuation)
                if use.rawValue > work.use.rawValue { work.use = use }
                pending[key] = work
            } else {
                pending[key] = Pending(id: UUID(), order: clock, use: use, waiters: [continuation])
            }
            startNext()
        }
    }

    private func startNext() {
        guard active == nil, let next = pending.max(by: {
            if $0.value.use != $1.value.use { return $0.value.use.rawValue < $1.value.use.rawValue }
            return $0.value.order > $1.value.order
        }) else { return }
        let key = next.key; let id = next.value.id
        active = id
        Task.detached(priority: next.value.use == .prefetch ? .utility : .userInitiated) {
            let result = Result {
                let image = try ImageDecoder.decode(at: key.url, maxPixelSize: key.pixels,
                    maximumBytes: key.highResolution ? 64 * 1024 * 1024 : 128 * 1024 * 1024)
                guard try FileRevision.read(key.url) == key.revision else { throw ReaderError.sourceChanged }
                return image
            }
            await self.finish(key, id: id, result: result)
        }
    }
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
            for waiter in work.waiters { waiter.resume(with: result) }
        }
        startNext()
    }
    private func remove(_ key: Key) {
        guard let value = values.removeValue(forKey: key) else { return }
        if key.highResolution { highResolutionBytes -= value.image.byteCount } else { bytes -= value.image.byteCount }
    }
    public func cancelPrefetch() {
        for key in pending.keys where pending[key]?.use == .prefetch {
            if let work = pending.removeValue(forKey: key) { for waiter in work.waiters { waiter.resume(throwing: CancellationError()) } }
        }
    }
    public func memoryPressure(critical: Bool) {
        cancelPrefetch()
        for key in pending.keys where key.highResolution {
            if let work = pending.removeValue(forKey: key) { for waiter in work.waiters { waiter.resume(throwing: CancellationError()) } }
        }
        for key in values.keys where values[key]?.use == .prefetch { remove(key) }
        for key in values.keys where key.highResolution { remove(key) }
        if critical { for key in Array(values.keys) { remove(key) } }
    }
    public func removeAll() {
        for work in pending.values { for waiter in work.waiters { waiter.resume(throwing: CancellationError()) } }
        pending.removeAll(); values.removeAll(); bytes = 0; highResolutionBytes = 0
    }
    public var byteCounts: (display: Int, loupe: Int) { (bytes, highResolutionBytes) }
}
