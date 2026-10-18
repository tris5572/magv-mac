import Foundation
import Testing
import CArchive
import Darwin
@testable import MagvCore

private func streamingFixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name) }
private func streamingTemporary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("magv-stream-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func makeZIP(_ url: URL, files: [(String, Data)]) throws {
    let writer = archive_write_new()!
    defer { archive_write_free(writer) }
    archive_write_set_format_zip(writer)
    archive_write_set_options(writer, "zip:compression=deflate")
    guard archive_write_open_filename(writer, url.path) == ARCHIVE_OK else { throw ReaderError.archive("test ZIP") }
    for (name, data) in files {
        let entry = archive_entry_new()!
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_perm(entry, 0o600)
        archive_entry_set_size(entry, Int64(data.count))
        guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw ReaderError.archive("test header") }
        let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
        guard written == data.count else { throw ReaderError.archive("test payload") }
    }
    guard archive_write_close(writer) == ARCHIVE_OK else { throw ReaderError.archive("test close") }
}

// 開く時点では表示対象だけを展開し、後続ページの容量で初期表示が妨げられないことを確認する。
@Test func archiveOpenExtractsOnlyRequestedPages() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let png = try Data(contentsOf: streamingFixture("portrait.png"))
    var later = png; later.append(Data(repeating: 0, count: 8 * 1024 * 1024))
    let zip = root.appendingPathComponent("large.zip")
    try makeZIP(zip, files: [("10.png", later), ("2.png", png), ("1.png", png)])
    let storage = try ExtractionStorage(root: root.appendingPathComponent("cache"), capacity: Int64(png.count * 3))
    let cache = SourceCache(storage: storage)
    let source = try await cache.load(zip)
    #expect(source.images.map(\.name) == ["1.png", "2.png", "10.png"])
    #expect(source.images.prefix(2).allSatisfy { $0.metadata?.orientation == .portrait })
    #expect(source.images[2].metadata == nil && !FileManager.default.fileExists(atPath: source.images[2].fileURL.path))
    #expect(storage.byteCount == Int64(png.count * 2))
    #expect(await source.archive?.extractionCount == 2)
    // 後続画像がディスク上限を超えていても、最初の見開きは開ける。
    await #expect(throws: ReaderError.limit("一時ディスクキャッシュ全体2GiB")) { _ = try await source.preparingImages(at: [2]) }
    #expect(storage.byteCount == Int64(png.count * 2))
    #expect(source.images.prefix(2).allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
}

// 読み終えた画像を順に削除し、展開総量がディスク上限を超える本も読み進められることを確認する。
@Test func pageDiskLRUAllowsReadingBeyondItsTotalCapacity() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let png = try Data(contentsOf: streamingFixture("portrait.png"))
    let zip = root.appendingPathComponent("many.zip")
    try makeZIP(zip, files: (1...40).reversed().map { ("\($0).png", png) })
    let storage = try ExtractionStorage(root: root.appendingPathComponent("cache"), capacity: Int64(png.count * 3))
    let source = try SourceLoader.load(zip, storage: storage)
    #expect(storage.byteCount == 0)
    for index in source.images.indices {
        let prepared = try await source.preparingImages(at: [index])
        #expect(try Data(contentsOf: prepared.images[index].fileURL) == png)
        #expect(storage.byteCount <= storage.capacity && storage.cachedFileCount <= 3)
        withExtendedLifetime(prepared) {}
    }
    #expect(!FileManager.default.fileExists(atPath: source.images[0].fileURL.path))
    let revisited = try await source.preparingImages(at: [0])
    #expect(try Data(contentsOf: revisited.images[0].fileURL) == png)
    #expect(await source.archive?.extractionCount == 41)
}

// 同じページへの同時要求が、1回の展開を共有することを確認する。
@Test func concurrentPageRequestsShareOneExtraction() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let cache = SourceCache(temporaryRoot: root)
    let source = try await cache.load(streamingFixture("images.zip"))
    let paths = try await withThrowingTaskGroup(of: URL.self) { group in
        for _ in 0..<12 { group.addTask { try await source.preparingImages(at: [2]).images[2].fileURL } }
        var paths: [URL] = []
        for try await path in group { paths.append(path) }
        return paths
    }
    #expect(Set(paths).count == 1)
    #expect(await source.archive?.extractionCount == 3)
}

// 重複パスを別項目として保ち、除外対象も含む全ヘッダーで安全性を検証することを確認する。
@Test func indexPreservesDuplicatePathsAndValidatesAllHeaders() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let portrait = try Data(contentsOf: streamingFixture("portrait.png"))
    let square = try Data(contentsOf: streamingFixture("square.png"))
    let zip = root.appendingPathComponent("duplicates.zip")
    try makeZIP(zip, files: [("same.png", portrait), ("same.png", square)])
    let source = try await SourceCache(temporaryRoot: root.appendingPathComponent("cache")).load(zip)
    #expect(Set(source.images.map(\.id)).count == 2)
    #expect(source.images[0].orientation == .portrait && source.images[1].orientation == .landscape)
    #expect(source.images[0].fileURL != source.images[1].fileURL)
    try makeZIP(root.appendingPathComponent("unsafe.zip"), files: [("1.png", portrait), ("../escape.png", portrait)])
    #expect(throws: ReaderError.self) { try ArchiveReader.index(root.appendingPathComponent("unsafe.zip")) }
    var limits = ReaderLimits(); limits.sourceBytes = Int64(portrait.count)
    #expect(throws: ReaderError.self) { try ArchiveReader.index(zip, limits: limits) }
    limits = ReaderLimits(); limits.entryCount = 1
    #expect(throws: ReaderError.self) { try ArchiveReader.index(zip, limits: limits) }
}

// RAR5の一覧専用モードと通常展開を分離し、ソリッド圧縮を継続して読めることを確認する。
@Test func rar5IndexOnlyReaderCannotDecodeAndNormalReaderResumesSolid() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let url = streamingFixture("test_read_format_rar5_multiple_files_solid.rar")
    let index = try ArchiveReader.index(url, include: { _ in true })
    #expect(index.members.count == 4)
    try withArchiveLocale {
        let reader = try ArchiveCursor(url: url, indexOnly: true)
        _ = try reader.next(limits: ReaderLimits(), ordinal: 0)
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(archive_read_data(reader.reader, &buffer, buffer.count) < 0)
    }
    let storage = try ExtractionStorage(root: root)
    let directory = try TemporaryDirectory(storage: storage)
    let worker = ArchiveExtractionWorker(url: url, index: index, directory: directory, limits: ReaderLimits())
    for position in [0, 3, 1, 2] {
        let prepared = try await worker.extract(index.members[position], to: directory.url.appendingPathComponent(UUID().uuidString), speculative: false)
        let bytes = [UInt8](try Data(contentsOf: prepared.file.url))
        #expect(bytes.count == 4096)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let k = offset / 4 + 1
            let expected = UInt32(max(0, k * k - 3 * k + 2 + position))
            let actual = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            #expect(actual == expected)
        }
    }
}

// ページ展開のキャンセルで、未完成ファイルと容量予約を解放することを確認する。
@Test func cancelledPageExtractionRemovesUnfinishedFileAndReservation() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let png = try Data(contentsOf: streamingFixture("portrait.png"))
    let zip = root.appendingPathComponent("cancel.zip")
    try makeZIP(zip, files: [("1.png", png + Data(repeating: 0, count: 1024 * 1024))])
    let index = try ArchiveReader.index(zip)
    let storage = try ExtractionStorage(root: root.appendingPathComponent("cache"))
    let directory = try TemporaryDirectory(storage: storage)
    let worker = ArchiveExtractionWorker(url: zip, index: index, directory: directory, limits: ReaderLimits(), progress: { _ in
        withUnsafeCurrentTask { $0?.cancel() }
    })
    let output = directory.url.appendingPathComponent("cancelled.png")
    let task = Task.detached { try await worker.extract(index.members[0], to: output, speculative: false) }
    do { _ = try await task.value; Issue.record("Cancelled extraction succeeded") }
    catch is CancellationError { }
    #expect(storage.byteCount == 0 && storage.cachedFileCount == 0)
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

// ページ単位のRAR展開結果を、全件展開した結果と比較する。
@Test(arguments: ["test_read_format_rar_compress_normal.rar", "test_read_format_rar5_compressed.rar"])
func selectiveRARReadsMatchFullExtraction(_ name: String) async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let url = streamingFixture(name)
    let expected = try ArchiveReader.extract(url, into: root, include: { _ in true })
    let index = try ArchiveReader.index(url, include: { _ in true })
    #expect(index.members.map(\.path) == expected.map(\.path))
    let directory = try TemporaryDirectory(root: root.appendingPathComponent("cache"))
    let worker = ArchiveExtractionWorker(url: url, index: index, directory: directory, limits: ReaderLimits())
    for position in index.members.indices.reversed() {
        let image = try await worker.extract(index.members[position], to: directory.url.appendingPathComponent(UUID().uuidString), speculative: false)
        #expect(try Data(contentsOf: image.file.url) == Data(contentsOf: expected[position].fileURL))
    }
}

// 一覧取得でもZIPの文字コードとZIP64を扱えることを確認する。
@Test(arguments: ["images.zip", "test_read_format_zip_filename_cp932.zip", "test_read_format_zip_zip64a.zip"])
func indexRetainsZIPNamesAndZIP64(_ name: String) throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let index = try ArchiveReader.index(streamingFixture(name), include: { _ in true })
    let extracted = try ArchiveReader.extract(streamingFixture(name), into: root, include: { _ in true })
    #expect(index.members.map(\.path) == extracted.map(\.path))
}

// 単体表示や横長ページでは、不要な2枚目の展開を待たないことを確認する。
@Test func singlePageAndLandscapeOpenDoNotWaitForSecondImage() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let portrait = try Data(contentsOf: streamingFixture("portrait.png"))
    let landscape = try Data(contentsOf: streamingFixture("square.png"))
    for (name, first, mode) in [("single", portrait, DisplayMode.single), ("landscape", landscape, .spread)] {
        let zip = root.appendingPathComponent(name + ".zip")
        try makeZIP(zip, files: [("1.png", first), ("2.png", portrait + Data(repeating: 0, count: 1024 * 1024))])
        let storage = try ExtractionStorage(root: root.appendingPathComponent(name), capacity: Int64(first.count))
        let source = try await SourceCache(storage: storage).load(zip, mode: mode)
        #expect(source.images[0].metadata != nil && source.images[1].metadata == nil)
        #expect(storage.byteCount == Int64(first.count))
        #expect(await source.archive?.extractionCount == 1)
    }
}

private final class DecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var released = false
    var started: Bool { count > 0 }
    var count: Int { condition.lock(); defer { condition.unlock() }; return calls }
    func pause() throws {
        condition.lock(); defer { condition.unlock() }
        calls += 1
        let deadline = Date().addingTimeInterval(5)
        while !released {
            guard condition.wait(until: deadline) else { throw ReaderError.archive("Decode gate timed out") }
        }
    }
    func resume() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

// 先読み待機のキャンセル有無や完了時点を変え、ページ移動が同じデコードを再利用することを確認する。
@Test(arguments: [false, true])
func pageTurnReusesActiveOrCompletedPrefetch(_ cancelConsumer: Bool) async throws {
    for finishBeforeDisplay in [false, true] {
        let gate = DecodeGate(); defer { gate.resume() }
        let cache = ImageCache(decoder: { url, pixels, bytes in
            try gate.pause()
            return try ImageDecoder.decode(at: url, maxPixelSize: pixels, maximumBytes: bytes)
        })
        let url = streamingFixture("portrait.png")
        let speculative = Task { try await cache.image(at: url, maxPixelSize: 1024, use: .prefetch) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.started)
        if cancelConsumer { speculative.cancel() } else { await cache.cancelPrefetch() }
        do { _ = try await speculative.value; Issue.record("Cancelled prefetch returned an image") } catch is CancellationError { }
        #expect(await cache.pendingRequestCount == 0)
        if finishBeforeDisplay {
            gate.resume()
            while await cache.isDecoding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(await cache.isDecoding == false)
        }
        let display = Task { try await cache.image(at: url, maxPixelSize: 1024) }
        if !finishBeforeDisplay {
            while await cache.pendingRequestCount == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(await cache.pendingRequestCount == 1)
            gate.resume()
        }
        let image = try await display.value
        let reused = try await cache.image(at: url, maxPixelSize: 1024)
        #expect(image.image === reused.image)
        #expect(gate.count == 1, "Page turn decoded the prefetched image again")
    }
}

// 破棄した先読みが後から完了しても、キャッシュへ再登録されないことを確認する。
@Test(arguments: [false, true])
func discardedActivePrefetchDoesNotRefillCache(_ removeAll: Bool) async throws {
    let gate = DecodeGate(); defer { gate.resume() }
    let cache = ImageCache(decoder: { url, pixels, bytes in
        try gate.pause()
        return try ImageDecoder.decode(at: url, maxPixelSize: pixels, maximumBytes: bytes)
    })
    let speculative = Task { try await cache.image(at: streamingFixture("portrait.png"), maxPixelSize: 1024, use: .prefetch) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !gate.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(gate.started)
    if removeAll { await cache.removeAll() } else { await cache.memoryPressure(critical: false) }
    do { _ = try await speculative.value; Issue.record("Discarded prefetch returned an image") } catch is CancellationError { }
    gate.resume()
    while await cache.isDecoding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await cache.isDecoding == false)
    #expect(await cache.byteCounts.display == 0)
}

// 待機要求のキャンセル後も、実デコードが終わるまでは展開ファイルを削除しないことを確認する。
@Test func cancelledPrefetchKeepsFilePinnedUntilDecoderActuallyFinishes() async throws {
    let root = try streamingTemporary(); defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ExtractionStorage(root: root)
    let gate = DecodeGate(); defer { gate.resume() }
    let cache = ImageCache(decoder: { url, pixels, bytes in
        try gate.pause()
        return try ImageDecoder.decode(at: url, maxPixelSize: pixels, maximumBytes: bytes)
    })
    var prepared: LoadedSource? = try SourceLoader.load(streamingFixture("images.zip"), storage: storage)
    prepared = try await prepared!.preparingImages(at: [0])
    let descriptor = prepared!.unpinned()
    let path = prepared!.images[0].fileURL
    func request(_ source: LoadedSource) -> Task<DecodedImage, Error> {
        Task { try await cache.image(at: path, maxPixelSize: 1024, use: .prefetch, retaining: source) }
    }
    let task = request(prepared!); prepared = nil
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !gate.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(gate.started)
    await cache.cancelPrefetch()
    do { _ = try await task.value; Issue.record("Cancelled prefetch returned an image") } catch is CancellationError { }
    storage.trimFiles()
    #expect(FileManager.default.fileExists(atPath: path.path))
    gate.resume()
    while await cache.isDecoding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await cache.isDecoding == false)
    storage.trimFiles()
    #expect(!FileManager.default.fileExists(atPath: path.path))
    withExtendedLifetime(descriptor) {}
}

// 実行中のデコードを待たず、不要になった待機中の表示要求をキャンセルできることを確認する。
@Test func obsoleteQueuedDisplayDecodeIsCancelledWithoutWaitingForActiveDecoder() async throws {
    let gate = DecodeGate(); defer { gate.resume() }
    let firstURL = streamingFixture("portrait.png")
    let cache = ImageCache(decoder: { url, pixels, bytes in
        #expect(url.path == firstURL.path)
        try gate.pause()
        return try ImageDecoder.decode(at: url, maxPixelSize: pixels, maximumBytes: bytes)
    })
    let first = Task { try await cache.image(at: firstURL, maxPixelSize: 1024) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !gate.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(gate.started)
    let obsolete = Task { try await cache.image(at: streamingFixture("square.png"), maxPixelSize: 1024) }
    while await cache.pendingRequestCount < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await cache.pendingRequestCount == 2)
    obsolete.cancel()
    do { _ = try await obsolete.value; Issue.record("Cancelled display request returned an image") } catch is CancellationError { }
    #expect(await cache.pendingRequestCount == 1)
    gate.resume()
    _ = try await first.value
    #expect(await cache.pendingRequestCount == 0)
}
