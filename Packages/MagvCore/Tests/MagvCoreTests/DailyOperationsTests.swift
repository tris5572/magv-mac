import Foundation
import Testing
@testable import MagvCore

private func testDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("magv-daily-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func write(_ name: String, in directory: URL, content: String = "archive data") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    return url
}

// 兄弟ソースの種類を絞り、自然順で列挙することを確認する。
@Test func siblingKindsAndNaturalOrder() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for name in ["10.RAR", "1.zip", "2.ZIP", ".hidden.zip", "image.png", "book.txt"] { _ = try write(name, in: root) }
    for name in ["folder10", "folder2", "folder1", ".hidden"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    #expect(try FileAccessService.siblings(of: root.appendingPathComponent("1.zip"), kind: .archive).map(\.lastPathComponent) == ["1.zip", "2.ZIP", "10.RAR"])
    #expect(try FileAccessService.siblings(of: root.appendingPathComponent("folder1"), kind: .directory).map(\.lastPathComponent) == ["folder1", "folder2", "folder10"])
    let hidden = root.appendingPathComponent(".hidden.zip")
    #expect(try FileAccessService.siblings(of: hidden, kind: .archive).contains(hidden))
}

// 兄弟一覧の両端で停止し、ランダム移動が現在の本を選ばないことを確認する。
@Test func siblingEdgesAndRandomExclusion() {
    let urls = ["1.zip", "2.zip", "10.zip"].map { URL(fileURLWithPath: "/books/" + $0) }
    #expect(SourceNavigator.destination(.previous, current: urls[0], siblings: urls) == nil)
    #expect(SourceNavigator.destination(.next, current: urls[2], siblings: urls) == nil)
    #expect(SourceNavigator.destination(.next, current: urls[0], siblings: urls) == urls[1])
    #expect(SourceNavigator.destination(.previous, current: urls[2], siblings: urls) == urls[1])
    #expect(SourceNavigator.destination(.random, current: urls[0], siblings: [urls[0]]) == nil)
    for _ in 0..<30 { #expect(SourceNavigator.destination(.random, current: urls[1], siblings: urls) != urls[1]) }
}

// 名前変更前に確保した兄弟URLが、変更後も同じ場所を表すことを確認する。
@Test func siblingURLsKeepTheirIdentityAfterRename() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("books", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try write("book1.zip", in: directory)
    let source = try write("book2.zip", in: directory).resolvingSymlinksInPath().standardizedFileURL
    let siblings = try FileAccessService.siblings(of: source, kind: .archive)
    #expect(siblings.contains(source))
    let renamed = try FileAccessService.renameArchive(at: source, baseName: "zz-renamed")
    let relocated = siblings.map { FileAccessService.sameLocation($0, source) ? renamed : $0 }
    #expect(relocated.contains(renamed))
    #expect(!relocated.contains(source))
    #expect(try FileAccessService.siblings(of: renamed, kind: .archive).contains(renamed))
}

// 名前変更で拡張子と内容を保ち、同名があれば上書きを避けることを確認する。
@Test func renamePreservesExtensionContentAndAvoidsCollisions() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try write("a.b.ZIP", in: root, content: "original bytes")
    _ = try write("日本語 a.b.ZIP", in: root, content: "existing bytes")
    _ = try write("日本語 a.b_.ZIP", in: root, content: "other bytes")
    let result = try FileAccessService.renameArchive(at: source, baseName: "日本語 a.b", expectedRevision: FileRevision.read(source))
    #expect(result.lastPathComponent == "日本語 a.b__.ZIP")
    #expect(try String(contentsOf: result, encoding: .utf8) == "original bytes")
    #expect(try String(contentsOf: root.appendingPathComponent("日本語 a.b.ZIP"), encoding: .utf8) == "existing bytes")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let prefixed = try FileAccessService.renameArchive(at: result, baseName: "!" + result.deletingPathExtension().lastPathComponent)
    #expect(prefixed.lastPathComponent == "!日本語 a.b__.ZIP")
    let again = try FileAccessService.renameArchive(at: prefixed, baseName: "!" + prefixed.deletingPathExtension().lastPathComponent)
    #expect(again.lastPathComponent == "!!日本語 a.b__.ZIP")
}

// 無効な名前の入力では、実ファイルが移動しないことを確認する。
@Test(arguments: ["", " ", ".", "..", "a/b", "a\\b", "a:b", "a\0b", "a\nb"])
func invalidNamesCannotMoveFiles(_ name: String) throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try write("book.zip", in: root)
    #expect(throws: ReaderError.invalidName) { try FileAccessService.renameArchive(at: source, baseName: name) }
    #expect(FileManager.default.fileExists(atPath: source.path))
}

// 同じ名前への変更と、アーカイブ以外を変更しない制限を確認する。
@Test func unchangedNameAndArchiveRestriction() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try write("a.b.rar", in: root)
    #expect(try FileAccessService.renameArchive(at: source, baseName: "a.b") == source)
    let image = try write("page.png", in: root)
    #expect(throws: ReaderError.unsupported) { try FileAccessService.renameArchive(at: image, baseName: "!page") }
}

// 同時に同じ宛先へ変更しても、既存ファイルを上書きしないことを確認する。
@Test func simultaneousRenameDoesNotOverwrite() async throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try write("a.zip", in: root, content: "a")
    let second = try write("b.zip", in: root, content: "b")
    async let a = Task.detached { try FileAccessService.renameArchive(at: first, baseName: "same") }.value
    async let b = Task.detached { try FileAccessService.renameArchive(at: second, baseName: "same") }.value
    let (one, two) = try await (a, b)
    #expect(one != two)
    #expect(Set([one.lastPathComponent, two.lastPathComponent]) == ["same.zip", "same_.zip"])
    #expect(try String(contentsOf: one, encoding: .utf8) == "a")
    #expect(try String(contentsOf: two, encoding: .utf8) == "b")
}

// 開いた後で置換されたファイルを、古い更新情報のまま名前変更しないことを確認する。
@Test func externallyReplacedArchiveIsNotRenamed() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try write("book.zip", in: root)
    let revision = try FileRevision.read(source)
    try FileManager.default.removeItem(at: source)
    _ = try write("book.zip", in: root, content: "external replacement")
    #expect(throws: ReaderError.sourceChanged) { try FileAccessService.renameArchive(at: source, baseName: "new", expectedRevision: revision) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "external replacement")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new.zip").path))
}

// 似た名前の別フォルダやシンボリックリンク経由で、許可範囲を越えないことを確認する。
@Test func folderGrantChecksPathBoundariesAndLinks() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("book")
    let other = root.appendingPathComponent("book2")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
    #expect(FileAccessService.contains(folder, folder.appendingPathComponent("page.png")))
    #expect(!FileAccessService.contains(folder, other.appendingPathComponent("page.png")))
    #expect(!FileAccessService.contains(folder, link.appendingPathComponent("page.png")))
}

// 検索URLで日本語と「+」などの文字が正しく保持されることを確認する。
@Test func searchRetainsJapaneseAndLiteralQueryCharacters() throws {
    let archive = URL(fileURLWithPath: "/books/日本語-a.b+&?#.ZIP")
    let url = try #require(SourceSearch.url(for: archive, kind: .archive))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "duckduckgo.com")
    #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "日本語 a.b+&?#")
    #expect(url.absoluteString.contains("%2B"))
    #expect(components.fragment == nil)
    let folderURL = try #require(SourceSearch.url(for: URL(fileURLWithPath: "/books/a.b", isDirectory: true), kind: .directory))
    #expect(URLComponents(url: folderURL, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "a.b")
    #expect(SourceSearch.url(for: URL(fileURLWithPath: "/books/---.zip"), kind: .archive) == nil)
}

// モニター構成の変更や異常な保存値があっても、画面内へウィンドウを復元することを確認する。
@Test func savedWindowIsReachableAcrossMonitorChanges() throws {
    let main = CGRect(x: 0, y: 40, width: 1440, height: 860)
    let secondary = CGRect(x: -1280, y: 50, width: 1280, height: 720)
    let minimum = CGSize(width: 320, height: 268)
    let saved = WindowFrame(CGRect(x: -1100, y: 100, width: 640, height: 508))
    #expect(WindowPlacement.restore(saved, visibleFrames: [main, secondary], minimumSize: minimum) == saved.rect)
    let unplugged = try #require(WindowPlacement.restore(saved, visibleFrames: [main], minimumSize: minimum))
    #expect(main.contains(unplugged))
    let huge = try #require(WindowPlacement.restore(WindowFrame(CGRect(x: 100000, y: 100000, width: 10000, height: 10000)), visibleFrames: [main], minimumSize: minimum))
    #expect(huge == main)
    let small = try #require(WindowPlacement.restore(WindowFrame(CGRect(x: 10, y: 50, width: 1, height: 1)), visibleFrames: [main], minimumSize: minimum))
    #expect(small.size == minimum)
    #expect(WindowPlacement.restore(WindowFrame(CGRect(x: 0, y: 0, width: 0, height: 20)), visibleFrames: [main], minimumSize: minimum) == nil)
    #expect(WindowPlacement.restore(WindowFrame(CGRect(x: Double.infinity, y: 0, width: 400, height: 300)), visibleFrames: [main], minimumSize: minimum) == nil)
    #expect(WindowPlacement.restore(saved, visibleFrames: [], minimumSize: minimum) == nil)
}

// 設定の保存・復元と、破損データからの復帰を確認する。
@Test func settingsRoundTripAndCorruptionRecovery() throws {
    let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(url: root.appendingPathComponent("support/settings.json"))
    #expect(store.load() == nil)
    var settings = ReaderSettings(); settings.displayMode = .single; settings.readingDirection = .leftToRight
    settings.window = SavedWindow(frame: WindowFrame(CGRect(x: 10, y: 20, width: 640, height: 508)))
    try store.save(settings)
    #expect(store.load() == settings)
    let json = try String(contentsOf: store.url, encoding: .utf8)
    #expect(!json.contains("history") && !json.contains("recent") && !json.contains("images"))
    try Data("broken".utf8).write(to: store.url); #expect(store.load() == nil)
    try Data("{\"schemaVersion\":99}".utf8).write(to: store.url); #expect(store.load() == nil)
    try Data("{\"schemaVersion\":1,\"window\":{\"frame\":{\"x\":0,\"y\":0,\"width\":-1,\"height\":10},\"coordinateSpace\":\"appkit-screen-points\"}}".utf8).write(to: store.url)
    #expect(store.load()?.window == nil)
    #expect(store.load()?.displayMode == .spread)
}
