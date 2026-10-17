import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
@testable import MagvCore

private let p = ImageOrientation.portrait
private let l = ImageOrientation.landscape
private let u = ImageOrientation.unknown
private func fixture(_ name: String) -> URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name) }
private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("magv-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func previousSpreadMatchesOriginalCases() {
    let cases: [([ImageOrientation], Int, Int, Bool)] = [
        ([p,p],1,0,true), ([p,l],1,0,true), ([l,p],1,0,true), ([l,l],1,0,true),
        ([p,p,p],2,0,false), ([l,p,p],2,1,true), ([p,l,p],2,1,true),
        ([p,p,l],2,0,false), ([l,p,l],2,1,true), ([p,l,l],2,1,true), ([l,l,l],2,1,true)
    ]
    for (orientations, index, expected, force) in cases {
        let page = PageNavigator.page(at: index, orientations: orientations, mode: .spread)
        let result = PageNavigator.move(.previous, from: page, orientations: orientations, mode: .spread)
        #expect(result?.anchorIndex == expected)
        #expect(result?.forceSingle == force)
    }
}

@Test func emptySingleSquareAndLastSpread() {
    #expect(PageNavigator.page(at: 0, orientations: [], mode: .spread) == nil)
    let one = PageNavigator.page(at: 0, orientations: [p], mode: .spread)
    #expect(PageNavigator.move(.last, from: one, orientations: [p], mode: .spread) == one)
    #expect(PageNavigator.page(at: 0, orientations: [p,l], mode: .spread)?.visibleIndices == [0])
    #expect(PageNavigator.page(at: 0, orientations: [p,u], mode: .spread)?.visibleIndices == [0])
    #expect(PageNavigator.page(at: 0, orientations: [p,p], mode: .single)?.visibleIndices == [0])
    let first = PageNavigator.page(at: 0, orientations: [p,p,p,p], mode: .spread)
    #expect(PageNavigator.move(.next, from: first, orientations: [p,p,p,p], mode: .spread)?.anchorIndex == 2)
    #expect(PageNavigator.move(.nextImage, from: first, orientations: [p,p,p,p], mode: .spread)?.anchorIndex == 1)
    let last = PageNavigator.move(.last, from: first, orientations: [p,p,p,p], mode: .spread)
    #expect(last?.visibleIndices == [2,3])
    #expect(PageNavigator.move(.nextImage, from: last, orientations: [p,p,p,p], mode: .spread) == last)
}

@Test func navigationAlwaysStaysInBounds() {
    for length in 1...6 {
        for code in 0..<Int(pow(3.0, Double(length))) {
            var code = code
            let orientations: [ImageOrientation] = (0..<length).map { _ in defer { code /= 3 }; return [p,l,u][code % 3] }
            for mode in [DisplayMode.single, .spread] {
                for index in -1...length {
                    let current = PageNavigator.page(at: index, orientations: orientations, mode: mode)
                    for command in PageCommand.allCases {
                        let result = PageNavigator.move(command, from: current, orientations: orientations, mode: mode)!
                        #expect((0..<length).contains(result.anchorIndex))
                        #expect((1...2).contains(result.visibleIndices.count))
                        #expect(result.visibleIndices.allSatisfy { (0..<length).contains($0) })
                        if result.visibleIndices.count == 2 {
                            #expect(mode == .spread)
                            #expect(result.visibleIndices.allSatisfy { orientations[$0] == .portrait })
                        }
                    }
                }
            }
        }
    }
}

@Test func indicatorClampsAndReverses() {
    #expect(PageNavigator.index(at: 0, count: 0, direction: .rightToLeft) == nil)
    #expect(PageNavigator.index(at: .nan, count: 10, direction: .rightToLeft) == nil)
    #expect(PageNavigator.index(at: -5, count: 10, direction: .leftToRight) == 0)
    #expect(PageNavigator.index(at: 5, count: 10, direction: .leftToRight) == 9)
    #expect(PageNavigator.index(at: 0, count: 10, direction: .rightToLeft) == 9)
    #expect(PageNavigator.index(at: 1, count: 10, direction: .rightToLeft) == 0)
    #expect(PageNavigator.index(at: 0.5, count: 1, direction: .rightToLeft) == 0)
    #expect(PageNavigator.progress(page: PageNavigator.page(at: 0, orientations: [p], mode: .spread), count: 1) == 1)
}

@Test func rar4DecodesRealPayload() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let entries = try ArchiveReader.extract(fixture("test_read_format_rar.rar"), into: dir, include: { _ in true })
    #expect(entries.map(\.path) == ["test.txt", "testdir/test.txt"])
    for entry in entries { #expect(try String(contentsOf: entry.fileURL, encoding: .utf8) == "test text document\r\n") }
}

@Test(arguments: ["test_read_format_rar5_compressed.rar", "test_read_format_rar5_multiple_files_solid.rar"])
func rar5PayloadMatchesGeneratedData(_ name: String) throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let entries = try ArchiveReader.extract(fixture(name), into: dir, include: { _ in true })
    #expect(entries.count == (name.contains("solid") ? 4 : 1))
    for (offset, entry) in entries.enumerated() {
        let bytes = [UInt8](try Data(contentsOf: entry.fileURL))
        #expect(bytes.count == (name.contains("solid") ? 4096 : 1200))
        let magic = name.contains("solid") ? offset + 1 : 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let k = index / 4 + 1
            let expected = UInt32(max(0, k * k - 3 * k + 1 + magic))
            let actual = UInt32(bytes[index]) | UInt32(bytes[index+1]) << 8 | UInt32(bytes[index+2]) << 16 | UInt32(bytes[index+3]) << 24
            #expect(actual == expected)
        }
    }
}

@Test(arguments: ["test_read_format_rar_unicode.rar", "test_read_format_rar5_unicode.rar"])
func rarUnicodeNames(_ name: String) throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let entries = try ArchiveReader.extract(fixture(name), into: dir, include: { _ in true })
    #expect(!entries.isEmpty)
    #expect(entries.contains { !$0.path.isASCII })
}

@Test(arguments: ["test_read_format_rar_encryption_data.rar", "test_read_format_rar4_solid_encrypted.rar", "test_read_format_rar5_solid_encrypted.rar"])
func encryptedArchivesAreRejected(_ name: String) throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: ReaderError.encrypted) { try ArchiveReader.extract(fixture(name), into: dir, include: { _ in true }) }
    #expect(throws: ReaderError.encrypted) { try ArchiveReader.index(fixture(name), include: { _ in true }) }
}

@Test func unsafePathsAndAppleMetadata() {
    for path in ["/abs.jpg", "../x.jpg", "a/../../x.jpg", "C:\\x.jpg", "a\\..\\x.jpg"] { #expect(!ArchiveReader.isSafePath(path)) }
    #expect(ArchiveReader.isSafePath("漫画/2.JPG"))
    for path in ["__MACOSX/1.jpg", "a/._1.jpg", "a/readme.txt"] { #expect(!ArchiveReader.isImagePath(path)) }
    #expect(ArchiveReader.isImagePath("漫画/2.JPG"))
}

@Test func zipNaturalOrderFilteringAndZIP64() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let entries = try ArchiveReader.extract(fixture("images.zip"), into: dir)
    #expect(entries.map(\.path) == ["漫画/1.png", "漫画/2.PNG", "漫画/10.png"])
    #expect(try ImageDecoder.metadata(at: entries[0].fileURL).orientation == .portrait)
    let zip64 = try ArchiveReader.extract(fixture("test_read_format_zip_zip64a.zip"), into: dir, include: { _ in true })
    #expect(!zip64.isEmpty)
}

@Test func archiveLimitsAndCorruption() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    var limits = ReaderLimits(); limits.imageBytes = 10
    #expect(throws: ReaderError.self) { try ArchiveReader.extract(fixture("images.zip"), into: dir, limits: limits) }
    limits = ReaderLimits(); limits.entryCount = 1
    #expect(throws: ReaderError.self) { try ArchiveReader.extract(fixture("images.zip"), into: dir, limits: limits) }
    limits = ReaderLimits(); limits.temporaryBytes = 10
    #expect(throws: ReaderError.self) { try ArchiveReader.extract(fixture("images.zip"), into: dir, limits: limits) }
    let corrupt = dir.appendingPathComponent("broken.zip"); try Data("broken".utf8).write(to: corrupt)
    #expect(throws: ReaderError.self) { try ArchiveReader.extract(corrupt, into: dir) }
    #expect(throws: ReaderError.self) { try ArchiveReader.extract(fixture("unsafe.zip"), into: dir) }
}

@Test func directoryAndDirectImageLoading() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = try Data(contentsOf: fixture("portrait.png"))
    for name in ["1.png", "10.png", "2.PNG", ".hidden.png"] { try image.write(to: dir.appendingPathComponent(name)) }
    let child = dir.appendingPathComponent("child"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try image.write(to: child.appendingPathComponent("3.png"))
    let loaded = try SourceLoader.load(dir.appendingPathComponent("2.PNG"))
    #expect(loaded.images.map(\.name) == ["1.png", "2.PNG", "10.png"])
    #expect(loaded.initialIndex == 1)
    #expect(loaded.url.path == dir.resolvingSymlinksInPath().path)
    let empty = dir.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(throws: ReaderError.self) { try SourceLoader.load(empty) }
}

@Test func imageFormatsAndSquare() throws {
    let metadata = try ImageDecoder.metadata(at: fixture("square.png")); #expect(metadata.orientation == .landscape)
    let image = try ImageDecoder.decode(at: fixture("portrait.png"), maxPixelSize: 10)
    #expect(max(image.image.width, image.image.height) == 10)
    let webp = try ImageDecoder.decode(at: fixture("pixel.webp"), maxPixelSize: 10)
    #expect(webp.image.width == 1 && webp.image.height == 1)
}

@Test func exifRotationChangesPortraitDecision() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let image = try ImageDecoder.decode(at: fixture("portrait.png"), maxPixelSize: 40).image
    let url = dir.appendingPathComponent("rotated.jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let metadata = try ImageDecoder.metadata(at: url)
    #expect(metadata.orientation == .landscape)
    let decoded = try ImageDecoder.decode(at: url, maxPixelSize: 40)
    #expect(decoded.image.width > decoded.image.height)
}

private extension String { var isASCII: Bool { unicodeScalars.allSatisfy(\.isASCII) } }

@Test func legacyJapaneseZIPNames() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let entries = try ArchiveReader.extract(fixture("test_read_format_zip_filename_cp932.zip"), into: dir, include: { _ in true })
    #expect(entries.map { $0.path.precomposedStringWithCanonicalMapping } == ["表だよ/一覧表.txt", "表だよ/漢字.txt"])
    for entry in entries { #expect(try Data(contentsOf: entry.fileURL).count == 5) }
}

@Test func canceledOpenCannotLoadSource() async throws {
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try SourceLoader.load(fixture("images.zip"))
    }
    do { _ = try await task.value; Issue.record("Canceled load unexpectedly succeeded") }
    catch is CancellationError { }
    catch { Issue.record("Expected cancellation, received \(error)") }
}

@Test(arguments: ["test_read_format_rar_compress_normal.rar", "test_read_format_rar_compress_best.rar"])
func compressedRAR4Payloads(_ name: String) throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    let entries = try ArchiveReader.extract(fixture(name), into: dir, include: { _ in true })
    #expect(entries.count == 3)
    let html = try Data(contentsOf: #require(entries.first { $0.path == "LibarchiveAddingTest.html" }).fileURL)
    #expect(html.count == 20111)
    let duplicate = try Data(contentsOf: #require(entries.first { $0.path == "testdir/LibarchiveAddingTest.html" }).fileURL)
    #expect(html == duplicate)
    let text = try String(contentsOf: #require(entries.first { $0.path == "testdir/test.txt" }).fileURL, encoding: .utf8)
    #expect(text == "test text document\r\n")
}

@Test func archiveSourceLifecycle() throws {
    let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
    func loadAndRelease() throws -> URL {
        let loaded = try SourceLoader.load(fixture("images.zip"), temporaryRoot: dir)
        #expect(loaded.kind == .archive)
        #expect(loaded.images.count == 3)
        #expect(loaded.images.allSatisfy { $0.metadata == nil })
        #expect(loaded.images.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        let extractedDirectory = try #require(loaded.temporaryDirectory?.url)
        #expect(FileManager.default.fileExists(atPath: extractedDirectory.path))
        return extractedDirectory
    }
    let extractedDirectory = try loadAndRelease()
    #expect(!FileManager.default.fileExists(atPath: extractedDirectory.path))
}
