import Foundation
import CoreGraphics
import Testing
@testable import MagvCore

private func aidFixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name) }
private func aidTemporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("magv-aids-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// 再生間隔の範囲・有限値・0.5秒刻みの入力制限を確認する。
@Test func slideshowIntervalsRejectInvalidOrFractionalSteps() {
    for text in ["", " ", "NaN", "inf", "-inf", "0", "-1", "0.25", "1.1", "100000.5", "abc"] {
        #expect(SlideshowInterval.parse(text) == nil)
    }
    for value in [0.5, 1, 5, 99999.5, 100000] { #expect(SlideshowInterval.parse(" \(value)\n") == value) }
}

// 余白を含む表示枠ではなく、配置済み画像とマウス位置からルーペを計算することを確認する。
@Test func loupeUsesActualFittedImageAndPointerCoordinates() {
    let leftSlot = CGRect(x: 0, y: 0, width: 500, height: 600)
    let rightSlot = leftSlot.offsetBy(dx: 500, dy: 0)
    let left = CanvasGeometry.imageRect(size: CGSize(width: 200, height: 400), slot: leftSlot, position: 0, count: 2)
    let right = CanvasGeometry.imageRect(size: CGSize(width: 100, height: 400), slot: rightSlot, position: 1, count: 2)
    #expect(left == CGRect(x: 200, y: 0, width: 300, height: 600))
    #expect(right == CGRect(x: 500, y: 0, width: 150, height: 600))
    #expect(CanvasGeometry.normalizedPoint(CGPoint(x: 199, y: 300), in: left) == nil)
    #expect(CanvasGeometry.normalizedPoint(CGPoint(x: 575, y: 150), in: left) == nil)
    let pointer = CGPoint(x: 575, y: 150)
    #expect(CanvasGeometry.normalizedPoint(pointer, in: right) == CGPoint(x: 0.5, y: 0.25))
    let lens = CGRect(x: 275, y: -150, width: 600, height: 600)
    let enlarged = CanvasGeometry.magnifiedRect(image: right, pointer: pointer, lens: lens)!
    #expect(enlarged.width == right.width * 8 && enlarged.height == right.height * 8)
    #expect(enlarged.minX + enlarged.width * 0.5 == lens.midX)
    #expect(enlarged.minY + enlarged.height * 0.25 == lens.midY)
    // 画面倍率はデコード解像度だけに反映し、ポイント座標や600ptのレンズ寸法は変えない。
    let metadata = ImageMetadata(width: 6000, height: 9000)
    #expect(CanvasGeometry.loupePixelSize(metadata: metadata, displayed: CGSize(width: 100, height: 150), backingScale: 1) == 1200)
    #expect(CanvasGeometry.loupePixelSize(metadata: metadata, displayed: CGSize(width: 100, height: 150), backingScale: 2) == 2400)
    let capped = CanvasGeometry.loupePixelSize(metadata: metadata, displayed: CGSize(width: 10000, height: 15000), backingScale: 2)
    #expect(capped <= 8192 && Double(capped * capped) / 1.5 <= Double(16 * 1024 * 1024))
    let resized = CanvasGeometry.imageRect(size: CGSize(width: 200, height: 400), slot: CGRect(x: 0, y: 0, width: 600, height: 300), position: 0, count: 1)
    #expect(resized == CGRect(x: 225, y: 0, width: 150, height: 300))
}

// 全ソースで展開容量を共有し、解放した分を再利用できることを確認する。
@Test func extractionBudgetCountsEveryLiveSourceAndReleasesSpace() throws {
    let root = try aidTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ExtractionStorage(root: root, capacity: 100)
    var first: TemporaryDirectory? = try TemporaryDirectory(storage: storage)
    let second = try TemporaryDirectory(storage: storage)
    try first!.reserve(60); try second.reserve(40)
    #expect(storage.byteCount == 100)
    #expect(throws: ReaderError.limit("一時ディスクキャッシュ全体2GiB")) { try second.reserve(1) }
    #expect(storage.byteCount == 100)
    let removed = first!.url; first = nil
    #expect(storage.byteCount == 40 && !FileManager.default.fileExists(atPath: removed.path))
    try second.reserve(60); #expect(storage.byteCount == 100)
}

// 所有マーカーとロックを確認し、他プロセスの領域やリンク先を清掃しないことを確認する。
@Test func orphanCleanupRespectsLocksMarkersAndSymlinks() throws {
    let root = try aidTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ExtractionStorage(root: root)
    let live = try TemporaryDirectory(storage: storage)
    let orphan = root.appendingPathComponent("magv-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    try Data("magv-extraction-v1\n".utf8).write(to: orphan.appendingPathComponent(".owner"))
    let unrelated = root.appendingPathComponent("magv-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
    try Data("unrelated".utf8).write(to: unrelated.appendingPathComponent(".owner"))
    let outside = try aidTemporary(); defer { try? FileManager.default.removeItem(at: outside) }
    try Data("magv-extraction-v1\n".utf8).write(to: outside.appendingPathComponent(".owner"))
    let link = root.appendingPathComponent("magv-" + UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    ExtractionStorage.cleanOrphans(in: root)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: live.url.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(FileManager.default.fileExists(atPath: link.path))
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent(".owner").path))
}

// 同じソースの展開共有と、実ファイル置換時のキャッシュ失効を確認する。
@Test func sourceCacheSharesExtractionAndInvalidatesReplacedFiles() async throws {
    let root = try aidTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("book.zip")
    try FileManager.default.copyItem(at: aidFixture("images.zip"), to: archive)
    let storage = try ExtractionStorage(root: root.appendingPathComponent("cache"))
    let cache = SourceCache(storage: storage)
    let paths = try await withThrowingTaskGroup(of: URL.self) { group in
        for _ in 0..<8 { group.addTask { try await cache.load(archive).temporaryDirectory!.url } }
        var result: [URL] = []
        for try await path in group { result.append(path) }
        return result
    }
    #expect(Set(paths).count == 1)
    let previous = try await cache.load(archive)
    let size = try previous.images.prefix(2).reduce(Int64(0)) { try $0 + Int64($1.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!) }
    #expect(storage.byteCount == size)
    // 同じ内容・サイズで不可分に置換してもinodeが変わるため、キャッシュキーは失効する。
    try Data(contentsOf: archive).write(to: archive, options: .atomic)
    let replaced = try await cache.load(archive)
    #expect(replaced.temporaryDirectory!.url != previous.temporaryDirectory!.url)
    // 外部で保持中の旧ソースは、最後の利用者が解放するまで読み込める。
    #expect(FileManager.default.fileExists(atPath: previous.images[0].fileURL.path))
    #expect(storage.byteCount == size * 2)
}

// フォルダ変更の再読み込みと、保持件数を超えた際の古いソースの削除を確認する。
@Test func sourceCacheRefreshesDirectoryAndEvictsLeastRecentlyUsed() async throws {
    let root = try aidTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let cache = SourceCache(temporaryRoot: root.appendingPathComponent("cache"), countLimit: 2)
    var archives: [URL] = []
    for index in 0..<3 {
        let url = root.appendingPathComponent("\(index).zip")
        try FileManager.default.copyItem(at: aidFixture("images.zip"), to: url); archives.append(url)
    }
    let first = try await cache.load(archives[0]).temporaryDirectory!.url
    let second = try await cache.load(archives[1]).temporaryDirectory!.url
    _ = try await cache.load(archives[0]); _ = try await cache.load(archives[2])
    #expect(await cache.cachedCount == 2)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    let dir = root.appendingPathComponent("pages")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    try FileManager.default.copyItem(at: aidFixture("portrait.png"), to: dir.appendingPathComponent("1.png"))
    #expect(try await cache.load(dir).images.count == 1)
    try FileManager.default.copyItem(at: aidFixture("square.png"), to: dir.appendingPathComponent("2.png"))
    #expect(try await cache.load(dir).images.count == 2)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("1.png"))
    #expect(try await cache.load(dir).images.count == 1)
}

// 容量不足でも保持中の本を消さず、失敗した展開の容量予約が残らないことを確認する。
@Test func fullDiskKeepsPinnedSourceAndFailedExtractionLeavesNoBytes() async throws {
    let root = try aidTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let entries = try ArchiveReader.extract(aidFixture("images.zip"), into: root)
    let size = try entries.prefix(2).reduce(Int64(0)) { try $0 + Int64($1.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!) }
    let storage = try ExtractionStorage(root: root.appendingPathComponent("cache"), capacity: size + 1)
    let cache = SourceCache(storage: storage)
    let first = try await cache.load(aidFixture("images.zip"))
    let other = root.appendingPathComponent("other.zip")
    try FileManager.default.copyItem(at: aidFixture("images.zip"), to: other)
    await #expect(throws: ReaderError.limit("一時ディスクキャッシュ全体2GiB")) { _ = try await cache.load(other) }
    #expect(storage.byteCount == size)
    #expect(FileManager.default.fileExists(atPath: first.images[0].fileURL.path))
    let emptyStorage = try ExtractionStorage(root: root.appendingPathComponent("empty-cache"), capacity: 1)
    let emptyCache = SourceCache(storage: emptyStorage)
    await #expect(throws: ReaderError.limit("一時ディスクキャッシュ全体2GiB")) {
        _ = try await emptyCache.load(other)
    }
    #expect(emptyStorage.byteCount == 0)
}

// 画像デコードの共有と、容量整理で先読み画像が先に削除されることを確認する。
@Test func imageCacheSharesDecodeAndDropsSpeculationFirst() async throws {
    let cache = ImageCache()
    async let a = cache.image(at: aidFixture("portrait.png"), maxPixelSize: 1024, use: .prefetch)
    async let b = cache.image(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    let pair = try await (a, b)
    #expect(pair.0.image === pair.1.image)
    let foregroundBytes = pair.0.byteCount
    _ = try await cache.image(at: aidFixture("square.png"), maxPixelSize: 1024, use: .prefetch)
    _ = try await cache.image(at: aidFixture("portrait.png"), maxPixelSize: 2048, use: .loupe)
    #expect(await cache.byteCounts.display > foregroundBytes)
    #expect(await cache.byteCounts.loupe > 0)
    await cache.memoryPressure(critical: false)
    #expect(await cache.byteCounts.display == foregroundBytes)
    #expect(await cache.byteCounts.loupe == 0)
    await cache.memoryPressure(critical: true)
    #expect(await cache.byteCounts.display == 0)
}

// キャッシュ容量とは別に、1回のデコードにもメモリ上限があることを確認する。
@Test func decoderHasSeparateMemoryBound() throws {
    #expect(throws: (any Error).self) {
        _ = try ImageDecoder.decode(at: aidFixture("portrait.png"), maxPixelSize: 8192, maximumBytes: 1)
    }
    let image = try ImageDecoder.decode(at: aidFixture("portrait.png"), maxPixelSize: 8192, maximumBytes: 1024)
    #expect(image.byteCount <= 1024)
}

// 名前変更後のURLでも、既存の展開結果を再利用できることを確認する。
@Test func archiveRenameKeepsCachedExtractionAtNewURL() async throws {
    let root = try aidTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old.zip")
    try FileManager.default.copyItem(at: aidFixture("images.zip"), to: old)
    let cache = SourceCache(temporaryRoot: root.appendingPathComponent("cache"))
    let original = try await cache.load(old)
    let renamedURL = try FileAccessService.renameArchive(at: old, baseName: "new", expectedRevision: original.revision)
    await cache.relocate(original.relocated(to: renamedURL), from: old)
    let reopened = try await cache.load(renamedURL)
    #expect(reopened.url == renamedURL)
    #expect(reopened.images.map(\.fileURL) == original.images.map(\.fileURL))
    #expect(await cache.cachedCount == 1)
}

// 画像キャッシュが容量を守りながら、最近使ったページを保持することを確認する。
@Test func imageLRURetainsRecentPageWithinByteBudget() async throws {
    let first = try ImageDecoder.decode(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    let second = try ImageDecoder.decode(at: aidFixture("square.png"), maxPixelSize: 1024)
    let limit = first.byteCount + second.byteCount
    let cache = ImageCache(capacity: limit)
    let portrait = try await cache.image(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    let square = try await cache.image(at: aidFixture("square.png"), maxPixelSize: 1024)
    _ = try await cache.image(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    _ = try await cache.image(at: aidFixture("pixel.webp"), maxPixelSize: 1024)
    #expect(await cache.byteCounts.display <= limit)
    let recent = try await cache.image(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    #expect(recent.image === portrait.image)
    let evicted = try await cache.image(at: aidFixture("square.png"), maxPixelSize: 1024)
    #expect(evicted.image !== square.image)
}

// ルーペと通常表示の画像が、共通のメモリ上限を守ることを確認する。
@Test func loupeAndDisplayShareTheTotalMemoryBudget() async throws {
    let first = try ImageDecoder.decode(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    let cache = ImageCache(capacity: first.byteCount, loupeCapacity: first.byteCount)
    _ = try await cache.image(at: aidFixture("portrait.png"), maxPixelSize: 1024)
    _ = try await cache.image(at: aidFixture("portrait.png"), maxPixelSize: 2048, use: .loupe)
    let counts = await cache.byteCounts
    #expect(counts.display + counts.loupe <= first.byteCount)
    #expect(counts.display == 0 && counts.loupe == first.byteCount)
}
