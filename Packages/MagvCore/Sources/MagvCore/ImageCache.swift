import Foundation

public actor ImageCache {
    private struct Key: Hashable { let url: URL; let size: Int; let modified: Date?; let pixels: Int }
    private struct Value { let image: DecodedImage; var touched: UInt64 }
    private var values: [Key: Value] = [:]
    private var pending: [Key: Task<DecodedImage, Error>] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private let capacity: Int
    private let worker = ImageDecodeWorker()
    public init(capacity: Int = 256 * 1024 * 1024) { self.capacity = capacity }

    public func image(at url: URL, maxPixelSize: Int) async throws -> DecodedImage {
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(url: url, size: attributes.fileSize ?? 0, modified: attributes.contentModificationDate, pixels: maxPixelSize)
        clock &+= 1
        if var value = values[key] {
            value.touched = clock; values[key] = value
            return value.image
        }
        if let task = pending[key] { return try await task.value }
        let task = Task { [worker] in try await worker.decode(url, maxPixelSize: maxPixelSize) }
        pending[key] = task
        do {
            let result = try await task.value
            pending[key] = nil
            if result.byteCount <= capacity {
                while bytes + result.byteCount > capacity, let oldest = values.min(by: { $0.value.touched < $1.value.touched }) {
                    bytes -= oldest.value.image.byteCount; values[oldest.key] = nil
                }
                clock &+= 1
                values[key] = Value(image: result, touched: clock); bytes += result.byteCount
            }
            return result
        } catch { pending[key] = nil; throw error }
    }

    public func removeAll() { values.removeAll(); bytes = 0 }
}

// Serial decoding bounds temporary allocations during rapid page changes.
private actor ImageDecodeWorker {
    func decode(_ url: URL, maxPixelSize: Int) throws -> DecodedImage {
        try ImageDecoder.decode(at: url, maxPixelSize: maxPixelSize)
    }
}
