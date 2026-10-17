import AppKit
import MagvCore
import CArchive
import ImageIO

// Compiled with the actual app's ReaderSession and InputRouter by test.sh.
@main struct SessionSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("magv-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: fixture.appendingPathComponent("portrait.png"))
        var folders: [URL] = []
        for index in 0..<21 {
            let dir = root.appendingPathComponent("book\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for page in 1...4 { try data.write(to: dir.appendingPathComponent("\(page).png")) }
            folders.append(dir)
        }
        let session = ReaderSession(preferences: ReaderPreferencesStore(store: nil), temporaryRoot: root.appendingPathComponent("cache"))
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "SessionSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitForOpen() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while session.isLoading || session.isRendering || session.isSelectingSource || session.isRenaming {
                if ContinuousClock.now > deadline { throw NSError(domain: "SessionSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Open timed out"]) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        session.open(folders[0]); try await waitForOpen()
        try require(session.source?.images.count == 4, "Folder load failed")
        session.jump(to: 2); try await waitForOpen()
        session.open(folders[1]); try await waitForOpen()
        session.open(folders[0]); try await waitForOpen()
        try require(session.page?.anchorIndex == 2, "In-process position wasn't restored")
        let currentURL = session.source?.url
        let currentPage = session.page
        session.open(root.appendingPathComponent("missing.zip")); try await waitForOpen()
        try require(session.source?.url == currentURL && session.page == currentPage, "Failed open replaced the current book")
        try require(session.errorMessage != nil, "Failed open wasn't reported")
        session.errorMessage = nil
        session.open(folders[2]); await Task.yield()
        session.open(folders[3]); session.open(folders[4]); try await waitForOpen()
        try await Task.sleep(for: .milliseconds(100))
        try require(session.source?.url == folders[4], "An obsolete open request replaced the latest book")
        session.open(folders[5]); session.cancelOpen(); try await waitForOpen()
        try require(session.source?.url == folders[4], "Cancel changed the current book")
        for folder in folders { session.open(folder); try await waitForOpen() }
        try require(session.recentURLs.count == 20, "Recent items weren't limited to 20")
        try require(Set(session.recentURLs).count == 20, "Recent items contain duplicates")
        session.open(folders[20]); try await waitForOpen()
        try require(session.recentURLs.count == 20 && session.recentURLs.first == folders[20], "Recent item order is incorrect")
        session.open(folders[0].appendingPathComponent("2.png")); try await waitForOpen()
        try require(session.page?.anchorIndex == 1, "Direct image did not override history")
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        try require(InputRouter.command(for: left, direction: .rightToLeft) == .next, "RTL arrow mapping failed")
        try require(InputRouter.command(for: left, direction: .leftToRight) == .previous, "LTR arrow mapping failed")
        let home = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 115)!
        try require(InputRouter.command(for: home, direction: .rightToLeft) == .last, "RTL Home mapping failed")
        try require(InputRouter.command(for: home, direction: .leftToRight) == .first, "LTR Home mapping failed")
        // Daily source switching preserves positions and stops at empty/deleted siblings.
        session.switchSource(.next); try await waitForOpen()
        try require(session.source?.url == folders[1], "Next sibling failed")
        session.switchSource(.previous); try await waitForOpen()
        try require(session.source?.url == folders[0] && session.page?.anchorIndex == 1, "Sibling revisit lost position")
        try require(!session.canSwitch(.previous), "First sibling did not stop")
        let beforeRandom = session.source?.url
        session.switchSource(.random); try await waitForOpen()
        try require(session.source?.url != beforeRandom, "Random selected the current source")
        session.open(folders[20]); try await waitForOpen()
        try require(!session.canSwitch(.next), "Last sibling did not stop")
        let empty = root.appendingPathComponent("book1.5", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        session.open(folders[1]); try await waitForOpen()
        session.switchSource(.next); try await waitForOpen()
        try require(session.source?.url == folders[1] && session.errorMessage?.contains("表示できる画像がありません") == true, "Empty sibling replaced or skipped the current book")
        session.errorMessage = nil
        try FileManager.default.removeItem(at: empty)
        session.switchSource(.next); try await waitForOpen()
        try require(session.source?.url == folders[1] && session.errorMessage != nil, "Deleted sibling was silently skipped")
        try require(!session.siblings.contains(empty), "Deleted sibling remained in the list")
        session.errorMessage = nil

        let archive = root.appendingPathComponent("a.b.ZIP")
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("images.zip"), to: archive)
        session.open(archive); try await waitForOpen()
        let oldImagePaths = session.source!.images.map(\.fileURL)
        session.jump(to: 2); try await waitForOpen()
        session.authorizeDirectory(root)
        session.beginRename(); try await waitForOpen()
        try require(session.isEditingName, "Rename editor did not start")
        func rename(_ name: String) async -> Result<Void, Error> {
            await withCheckedContinuation { continuation in
                session.renameArchive(to: name) { continuation.resume(returning: $0) }
            }
        }
        let invalid = await rename("../invalid")
        if case .success = invalid { throw NSError(domain: "SessionSmoke", code: 3) }
        try require(session.isEditingName && session.source?.url == archive, "Rename failure lost editing or reader state")
        let renamedResult = await rename("日本語 a.b")
        try renamedResult.get()
        session.isEditingName = false
        let renamed = root.appendingPathComponent("日本語 a.b.ZIP")
        try require(session.source?.url == renamed && session.title == "日本語 a.b.ZIP", "Rename title/identity did not update")
        try require(session.page?.anchorIndex == 2 && session.source?.images.map(\.fileURL) == oldImagePaths, "Rename discarded page/cache data")
        try require(!session.recentURLs.contains(archive) && session.recentURLs.contains(renamed), "Rename left old history identity")
        session.open(folders[0]); try await waitForOpen()
        session.open(renamed); try await waitForOpen()
        try require(session.page?.anchorIndex == 2, "Renamed book position was not restored")
        let conflict = root.appendingPathComponent("!日本語 a.b.ZIP")
        try Data("existing bytes".utf8).write(to: conflict)
        session.addBangPrefix(); try await waitForOpen()
        let prefixed = root.appendingPathComponent("!日本語 a.b_.ZIP")
        try require(session.source?.url == prefixed, "Bang prefix corrupted multiple-dot name or failed collision handling")
        try require(try String(contentsOf: conflict, encoding: .utf8) == "existing bytes", "Bang prefix overwrote an existing file")
        try require(try Data(contentsOf: prefixed) == Data(contentsOf: fixture.appendingPathComponent("images.zip")), "Rename changed archive contents")

        // An access panel response for an earlier book must never edit a later book.
        let permissionSession = ReaderSession(preferences: ReaderPreferencesStore(store: nil), temporaryRoot: root.appendingPathComponent("other-cache"))
        permissionSession.open(prefixed)
        while permissionSession.isLoading || permissionSession.isRendering { try await Task.sleep(for: .milliseconds(5)) }
        var grantCompletion: ((URL?) -> Void)?
        permissionSession.requestDirectoryAccess = { directory, _, completion in
            precondition(FileAccessService.sameLocation(directory, root)); grantCompletion = completion
        }
        permissionSession.beginRename()
        try require(grantCompletion != nil && !permissionSession.isEditingName, "Rename assumed a file grant also authorized its parent")
        permissionSession.open(folders[2])
        while permissionSession.isLoading || permissionSession.isRendering { try await Task.sleep(for: .milliseconds(5)) }
        grantCompletion?(root)
        try require(permissionSession.source?.url == folders[2] && !permissionSession.isEditingName, "Stale folder grant edited another source")

        try require(!RenameFieldEditor.shouldSubmit(hasMarkedText: true, wasComposing: false), "IME marked text submitted")
        try require(!RenameFieldEditor.shouldSubmit(hasMarkedText: false, wasComposing: true), "IME commit Return also submitted")
        try require(RenameFieldEditor.shouldSubmit(hasMarkedText: false, wasComposing: false), "Normal Return did not submit")
        let bang = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        try require(InputRouter.action(for: bang, direction: .rightToLeft) == .addBang, "Bang depended on a physical key")
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        try require(InputRouter.action(for: down, direction: .rightToLeft) == .source(.next), "Source key routing failed")
        let store = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let preferences = ReaderPreferencesStore(store: store)
        let settingsSession = ReaderSession(preferences: preferences)
        settingsSession.mode = .single; settingsSession.direction = .leftToRight
        preferences.setWindowFrame(CGRect(x: 30, y: 40, width: 640, height: 508)); preferences.flush()
        let restored = ReaderSession(preferences: ReaderPreferencesStore(store: store))
        try require(restored.mode == .single && restored.direction == .leftToRight && restored.source == nil && restored.recentURLs.isEmpty, "Persistence restored history or lost display preferences")
        try require(store.load()?.window?.frame.width == 640, "Window frame wasn't persisted")
        let access = SessionFileAccess()
        let selectedImage = folders[0].appendingPathComponent("2.png")
        access.retain(selectedImage); access.remember(source: folders[0], selected: selectedImage)
        try require(access.reopeningURL(for: folders[0]) == selectedImage, "Recent image lost its original scoped URL")
        access.retain(folders[1], asDirectoryGrant: true)
        access.trim(to: [folders[0]])
        try require(!access.covers(folders[1]), "Unused folder grants weren't released")
        access.retain(folders[0], asDirectoryGrant: true)
        try require(access.reopeningURL(for: folders[0]) == folders[0], "Folder grant did not replace partial image access")
        let recentImageSession = ReaderSession(preferences: ReaderPreferencesStore(store: nil))
        recentImageSession.open(selectedImage)
        while recentImageSession.isLoading || recentImageSession.isRendering { try await Task.sleep(for: .milliseconds(5)) }
        recentImageSession.jump(to: 3)
        recentImageSession.open(folders[1])
        while recentImageSession.isLoading || recentImageSession.isRendering { try await Task.sleep(for: .milliseconds(5)) }
        recentImageSession.open(folders[0], userSelection: false)
        while recentImageSession.isLoading || recentImageSession.isRendering { try await Task.sleep(for: .milliseconds(5)) }
        try require(recentImageSession.page?.anchorIndex == 3, "Recent image source reset to the originally selected image")
        try await streamingNavigationSmoke(root: root, fixture: fixture)
        try await readingAidSmoke(root: root, fixture: fixture, folder: folders[0])
        try await pagePresentationSmoke(root: root, fixture: fixture, verifyCanvas: CommandLine.arguments.contains("--ui"))
        print("Session smoke passed: slideshow/loupe/memory pressure and core reader, sibling switching, empty/deleted candidates, rename/history/cache, bang collision, stale grants, IME guard, settings")
        if CommandLine.arguments.contains("--ui") { try await renameSheetSmoke(root: root, fixture: fixture) }
    }
}

// Opt-in: exercises AppKit's actual field editor and sheet without showing a reader window.
@MainActor private func renameSheetSmoke(root: URL, fixture: URL) async throws {
    _ = NSApplication.shared
    let directory = root.appendingPathComponent("rename-sheet", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = directory.appendingPathComponent("original.a.ZIP")
    let bytes = try Data(contentsOf: fixture.appendingPathComponent("images.zip"))
    try bytes.write(to: original)
    let session = ReaderSession(preferences: ReaderPreferencesStore(store: nil), temporaryRoot: directory.appendingPathComponent("cache"))
    defer { session.shutdown() }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "RenameSheetSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func settle(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready() {
            try require(ContinuousClock.now < deadline, "Rename sheet timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    session.open(original)
    try await settle { !session.isLoading && !session.isRendering }
    try require(session.source?.url == original, "Rename fixture did not open")
    session.authorizeDirectory(directory)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func exercise(button: Bool, attempts: [(String, Bool)]) async throws {
        guard let source = session.source else { throw ReaderError.missing }
        var submitted: String?
        var result: Result<Void, Error>?
        var finished = false
        session.isEditingName = true
        let sheet = RenameSheetController(source: source, previous: nil, next: nil, submit: { name, completion in
            submitted = name
            session.renameArchive(to: name) { value in result = value; completion(value) }
        }, finished: { finished = true; session.isEditingName = false })
        sheet.present(on: window)
        defer { sheet.dismiss() }
        let views = descendants(sheet.panel.contentView!)
        guard let field = views.compactMap({ $0 as? NSTextField }).first(where: \.isEditable),
              let change = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "変更" }),
              let editor = field.currentEditor() as? NSTextView else { throw ReaderError.rename("Missing field editor") }
        editor.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try require(submitted == nil && !finished, "IME composition submitted a rename")
        editor.unmarkText()
        for (name, succeeds) in attempts {
            submitted = nil; result = nil
            let oldURL = session.source!.url
            let oldPage = session.page
            sheet.panel.makeFirstResponder(field)
            guard let active = field.currentEditor() as? NSTextView else { throw ReaderError.rename("Missing retry editor") }
            active.insertText(name, replacementRange: NSRange(location: 0, length: active.string.utf16.count))
            if button { change.performClick(nil) }
            else { active.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            try await settle { result != nil }
            try require(submitted == name, "Rename submitted stale field text")
            switch result! {
            case .success:
                try require(succeeds && finished, "Invalid name was accepted or sheet did not close")
                let newURL = directory.appendingPathComponent(name).appendingPathExtension(oldURL.pathExtension)
                try require(!FileManager.default.fileExists(atPath: oldURL.path), "Original file still exists after rename")
                try require(try Data(contentsOf: newURL) == bytes, "Renamed file is missing or changed")
                try require(session.source?.url == newURL && session.presentedPage?.sourceURL == newURL && session.title == newURL.lastPathComponent && session.page == oldPage,
                            "Rename sheet lost reader identity or page")
            case .failure:
                try require(!succeeds && !finished && field.isEnabled && field.stringValue == name, "Failed rename lost the edited name")
                try require(session.source?.url == oldURL && (try Data(contentsOf: oldURL)) == bytes, "Failed rename changed the file")
            }
        }
    }
    try await exercise(button: false, attempts: [("日本語 a.b", true)])
    try await exercise(button: true, attempts: [("invalid/name", false), ("変更ボタンで確定", true)])
    print("Rename sheet smoke passed: active field editor, Return/button, invalid-name retry, IME guard, on-disk rename")
}

@MainActor private func pagePresentationSmoke(root: URL, fixture: URL, verifyCanvas: Bool) async throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PagePresentationSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let folder = root.appendingPathComponent("presentation-pages", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (index, color) in [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 1.0, 0.0]].enumerated() {
        let context = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(index).png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Could not create colored test page")
    }
    try Data("broken image".utf8).write(to: folder.appendingPathComponent("4.png"))
    let reader = ReaderSession(preferences: ReaderPreferencesStore(store: nil), temporaryRoot: root.appendingPathComponent("presentation-cache"))
    defer { reader.shutdown() }
    reader.mode = .single
    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading || reader.isRendering {
            try require(ContinuousClock.now < deadline, "Presentation timed out")
            if let frame = reader.presentedPage {
                try require(frame.page.visibleIndices.allSatisfy { frame.images[$0] != nil || frame.failureNames[$0] != nil }, "Published a partial frame")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(reader.presentedPage?.sourceURL == reader.source?.url && reader.presentedPage?.page == reader.page,
                    "Presented frame did not catch up with navigation")
    }
    func pixels() -> Data? {
        guard verifyCanvas else { return nil }
        _ = NSApplication.shared
        let canvas = CanvasView(session: reader)
        canvas.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        let context = CGContext(data: nil, width: 320, height: 480, bitsPerComponent: 8, bytesPerRow: 1280,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
    }
    reader.open(folder); try await settle()
    reader.loupeEnabled = true
    let first = reader.presentedPage!
    let firstPixels = pixels()
    reader.move(.next)
    try require(reader.page?.anchorIndex == 1 && reader.presentedPage?.page == first.page && reader.decoded[0]?.image === first.images[0]?.image,
                "Next page discarded the visible image before decode")
    try require(!reader.canUseLoupe && pixels() == firstPixels, "Pending navigation changed the canvas or used an old loupe")
    try await settle()
    let secondPixels = pixels()
    try require(!verifyCanvas || secondPixels != firstPixels, "Canvas never switched to the new colored page")
    let second = reader.presentedPage!.page
    reader.jump(to: 2); reader.jump(to: 3)
    try require(reader.presentedPage?.page == second && pixels() == secondPixels, "Rapid jumps cleared the visible page")
    try await settle()
    try require(reader.presentedPage?.page.anchorIndex == 3, "An obsolete render replaced the latest jump")
    reader.mode = .spread; reader.jump(to: 0); try await settle()
    let spread = reader.presentedPage!
    let spreadPixels = pixels()
    reader.move(.next)
    try require(reader.presentedPage?.page == spread.page && pixels() == spreadPixels, "Spread transition cleared or rearranged the previous spread")
    try await settle()
    try require(reader.presentedPage?.page.visibleIndices == [2, 3] && reader.decoded.count == 2, "Spread was not committed together")
    let resizedPage = reader.presentedPage!.page
    reader.updatePixelSize(3072)
    try require(reader.presentedPage?.page == resizedPage && reader.decoded.count == 2, "Resize cleared the current spread")
    try await settle()
    reader.mode = .single; reader.jump(to: 0); try await settle()
    reader.jump(to: 4)
    try require(reader.presentedPage?.page.anchorIndex == 0, "Failed-image navigation cleared the old page early")
    try await settle()
    try require(reader.presentedPage?.failureNames[4] == "4.png" && reader.decoded.isEmpty, "Failed page left a stale image instead of an error slot")
    reader.jump(to: 0); try await settle()
    let beforeOpen = reader.presentedPage!.page
    let archive = fixture.appendingPathComponent("images.zip")
    reader.open(archive)
    try require(reader.presentedPage?.sourceURL == folder && reader.presentedPage?.page == beforeOpen, "Opening another book cleared its predecessor early")
    try await settle()
    let archivePage = reader.presentedPage!.page
    reader.move(.next); reader.cancelPageLoad(); try await settle()
    try require(reader.presentedPage?.page == archivePage, "Cancelled archive preparation changed the visible frame")
    reader.jump(to: 2); reader.jump(to: 0); try await settle()
    try require(reader.presentedPage?.page.anchorIndex == 0, "Stale archive render replaced the latest jump")
    reader.move(.next); reader.open(folder); try await settle()
    try require(reader.presentedPage?.sourceURL == folder, "Archive render crossed a source boundary")
    reader.shutdown()
    try require(reader.presentedPage == nil && reader.decoded.isEmpty, "Shutdown retained the presented frame")
    print("Page presentation smoke passed: retained frame, atomic spread, rapid jumps, resize, failures, archive cancellation/source switch\(verifyCanvas ? ", canvas pixel comparison" : "")")
}

// Intentionally ignore cancellation here, so stale timer completions exercise the session's generation guard.
private actor SlideshowGate {
    private var next = 0
    private var waits: [Int: CheckedContinuation<Void, Error>] = [:]
    private var delays: [Int: Duration] = [:]
    func wait(_ delay: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            next += 1; waits[next] = continuation; delays[next] = delay
        }
    }
    var count: Int { next }
    func delay(_ id: Int) -> Duration? { delays[id] }
    func fire(_ id: Int) { waits.removeValue(forKey: id)?.resume() }
    func drain() { for continuation in waits.values { continuation.resume() }; waits.removeAll() }
}

@MainActor private func readingAidSmoke(root: URL, fixture: URL, folder: URL) async throws {
    let gate = SlideshowGate()
    let reader = ReaderSession(preferences: ReaderPreferencesStore(store: nil), temporaryRoot: root.appendingPathComponent("aid-cache"), wait: { try await gate.wait($0) })
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ReadingAidSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading || reader.isRendering || reader.isSelectingSource || reader.isRenaming {
            try require(ContinuousClock.now < deadline, "Reading aid render timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func timer(after previous: Int) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.count <= previous {
            try require(ContinuousClock.now < deadline, "Slideshow failed to schedule")
            try await Task.sleep(for: .milliseconds(5))
        }
        return await gate.count
    }
    func fireAndSettle(_ id: Int) async throws {
        await gate.fire(id); try await Task.sleep(for: .milliseconds(10)); try await settle()
    }
    try require(!reader.loupeEnabled && !reader.isSlideshowPlaying && reader.slideshowInterval == 5, "Reading aid defaults changed")
    reader.open(folder); try await settle()
    reader.toggleSlideshow()
    var tick = try await timer(after: 0)
    try require(await gate.delay(tick) == .seconds(5), "Initial interval was not five seconds")
    try await fireAndSettle(tick)
    try require(reader.page?.visibleIndices == [2, 3] && !reader.isSlideshowPlaying, "Spread slideshow did not advance once and stop at the final image")
    reader.toggleSlideshow(); try require(!reader.isSlideshowPlaying, "Slideshow started at the end")

    reader.mode = .single; reader.jump(to: 0); try await settle(); reader.toggleSlideshow()
    tick = try await timer(after: tick)
    let staleManual = tick
    reader.move(.next); try await settle(); tick = try await timer(after: tick)
    try await fireAndSettle(staleManual)
    try require(reader.page?.anchorIndex == 1, "A timer from before manual navigation advanced the page")
    try await fireAndSettle(tick); tick = try await timer(after: tick)
    try require(reader.page?.anchorIndex == 2 && reader.isSlideshowPlaying, "Single-page slideshow advanced incorrectly")
    let staleInterval = tick
    try require(reader.setSlideshowInterval("0.5"), "Valid interval was rejected")
    tick = try await timer(after: tick)
    try require(await gate.delay(tick) == .milliseconds(500), "Interval change didn't reset the full wait")
    try require(!reader.setSlideshowInterval("nan") && reader.slideshowInterval == 0.5, "Invalid interval replaced the current value")
    try await fireAndSettle(staleInterval)
    try require(reader.page?.anchorIndex == 2, "Stale interval timer advanced")
    try await fireAndSettle(tick)
    try require(reader.page?.anchorIndex == 3 && !reader.isSlideshowPlaying, "Final single page didn't stop playback")

    reader.jump(to: 0); try await settle(); reader.toggleSlideshow(); tick = try await timer(after: tick)
    let sleepTimer = tick
    reader.suspendSlideshow(); try await fireAndSettle(sleepTimer)
    try require(reader.page?.anchorIndex == 0 && reader.isSlideshowPlaying, "Sleep advanced or lost playback state")
    reader.resumeSlideshow(); tick = try await timer(after: tick)
    let beforeJump = tick
    reader.jump(to: 1); try await settle(); tick = try await timer(after: tick)
    try await fireAndSettle(beforeJump)
    try require(reader.page?.anchorIndex == 1, "Direct page selection didn't reset elapsed time")
    let beforeMode = tick
    reader.mode = .spread; try await settle(); tick = try await timer(after: tick)
    try await fireAndSettle(beforeMode)
    try require(reader.page?.anchorIndex == 1, "Display recalculation didn't reset elapsed time")
    let beforeDirection = tick
    reader.direction = .leftToRight; tick = try await timer(after: tick)
    try await fireAndSettle(beforeDirection)
    try require(reader.page?.anchorIndex == 1, "Reading direction change didn't reset elapsed time")
    reader.isEditingInterval = true
    let beforeEditor = tick
    try require(!reader.canRead && reader.isSlideshowPlaying, "Interval editing did not suspend reading")
    try await fireAndSettle(beforeEditor)
    try require(reader.page?.anchorIndex == 1, "Interval editor allowed timer navigation")
    reader.setSlideshowInterval("10"); reader.isEditingInterval = false
    tick = try await timer(after: tick)
    try require(await gate.delay(tick) == .seconds(10), "Interval editor didn't restart the full wait")
    reader.open(root.appendingPathComponent("missing-aid.zip")); try await settle()
    try require(!reader.isSlideshowPlaying && reader.source?.url == folder, "Failed source switch continued slideshow or replaced the source")
    reader.errorMessage = nil

    reader.mode = .single; reader.jump(to: 0); try await settle(); reader.loupeEnabled = true
    reader.requestLoupe(index: 0, displayedSize: CGSize(width: 300, height: 600), backingScale: 2)
    let loupeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while reader.loupeImage == nil {
        try require(ContinuousClock.now < loupeDeadline, "Loupe decode timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
    try require(reader.loupeIndex == 0, "Loupe referenced another image")
    reader.move(.next); try await settle()
    try require(reader.loupeImage == nil && reader.loupeIndex == nil, "Old loupe survived a page change")
    reader.requestLoupe(index: 1, displayedSize: CGSize(width: 300, height: 600), backingScale: 2)
    reader.handleMemoryPressure(critical: true)
    try await Task.sleep(for: .milliseconds(20))
    reader.requestLoupe(index: 1, displayedSize: CGSize(width: 300, height: 600), backingScale: 2)
    try require(!reader.canUseLoupe && reader.loupeImage == nil && !reader.decoded.isEmpty, "Memory pressure rebuilt the loupe or lost the visible page")
    reader.memoryPressureEnded(); try require(reader.canUseLoupe, "Loupe remained disabled after pressure ended")
    reader.loupeEnabled = false
    reader.toggleSlideshow(); tick = try await timer(after: tick)
    reader.closeWindow(); try await fireAndSettle(tick)
    try require(!reader.isSlideshowPlaying && reader.page?.anchorIndex == 1, "Window close left playback running")
    reader.toggleSlideshow(); try require(!reader.isSlideshowPlaying && !reader.canRead, "Playback restarted while the reader window was closed")
    reader.resumeWindow(); try await settle()
    try require(reader.decoded[1] != nil, "Window reopen didn't restore rendering")

    let bad = root.appendingPathComponent("bad-pages")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("portrait.png"), to: bad.appendingPathComponent("0.png"))
    try Data("broken image".utf8).write(to: bad.appendingPathComponent("1.png"))
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("portrait.png"), to: bad.appendingPathComponent("2.png"))
    reader.open(bad); try await settle(); reader.toggleSlideshow(); tick = try await timer(after: tick)
    try await fireAndSettle(tick)
    try require(reader.page?.anchorIndex == 1 && !reader.isSlideshowPlaying && reader.imageFailures[1] != nil, "Image failure didn't stop playback")
    let archive = root.appendingPathComponent("aid-rename.zip")
    try FileManager.default.copyItem(at: fixture.appendingPathComponent("images.zip"), to: archive)
    reader.open(archive); try await settle(); reader.authorizeDirectory(root)
    reader.toggleSlideshow(); tick = try await timer(after: tick)
    reader.beginRename(); try await settle(); try await fireAndSettle(tick)
    try require(reader.isEditingName && !reader.isSlideshowPlaying && reader.page?.anchorIndex == 0, "Rename didn't stop playback")
    reader.isEditingName = false; reader.stopSlideshow(); await gate.drain()
    reader.closeWindow()
}

@MainActor private func streamingNavigationSmoke(root: URL, fixture: URL) async throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "StreamingSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let portrait = try Data(contentsOf: fixture.appendingPathComponent("portrait.png"))
    let landscape = try Data(contentsOf: fixture.appendingPathComponent("square.png"))
    let orientations: [ImageOrientation] = [.portrait, .landscape, .portrait, .portrait, .landscape, .portrait, .portrait]
    let url = root.appendingPathComponent("mixed-streaming.zip")
    let writer = archive_write_new()!
    archive_write_set_format_zip(writer)
    try require(archive_write_open_filename(writer, url.path) == ARCHIVE_OK, "ZIP writer failed")
    for index in orientations.indices.reversed() {
        let entry = archive_entry_new()!
        archive_entry_set_pathname_utf8(entry, "\(index + 1).png")
        archive_entry_set_filetype(entry, 0o100000); archive_entry_set_perm(entry, 0o600)
        let data = orientations[index] == .portrait ? portrait : landscape
        archive_entry_set_size(entry, Int64(data.count))
        try require(archive_write_header(writer, entry) == ARCHIVE_OK, "ZIP header failed")
        let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
        archive_entry_free(entry)
        try require(written == data.count, "ZIP payload failed")
    }
    archive_write_close(writer); archive_write_free(writer)
    let slideshow = SlideshowGate()
    let reader = ReaderSession(preferences: ReaderPreferencesStore(store: nil), temporaryRoot: root.appendingPathComponent("stream-cache"), wait: { try await slideshow.wait($0) })
    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reader.isLoading || reader.isRendering {
            try require(ContinuousClock.now < deadline, "Streaming navigation timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    reader.open(url); try await settle()
    var expected = PageNavigator.page(at: 0, orientations: orientations, mode: .spread)
    try require(reader.page == expected && reader.source?.images[6].metadata == nil, "Streaming open did not keep unvisited metadata lazy")
    for command: PageCommand in [.last, .previous, .previous, .nextImage, .previousImage, .first, .next, .next, .next, .previous] {
        expected = PageNavigator.move(command, from: expected, orientations: orientations, mode: .spread)
        reader.move(command); try await settle()
        try require(reader.page == expected, "Lazy metadata changed navigation semantics: \(command)")
        try require(reader.page!.visibleIndices.allSatisfy { reader.decoded[$0] != nil }, "An unmaterialized page was decoded")
    }
    reader.jump(to: 0); try await settle()
    expected = reader.page
    for _ in 0..<3 {
        expected = PageNavigator.move(.next, from: expected, orientations: orientations, mode: .spread)
        reader.move(.next)
    }
    try await settle(); try require(reader.page == expected, "Rapid queued next-page commands were dropped or used unknown orientations")
    reader.jump(to: 6); reader.jump(to: 2); reader.jump(to: 0); try await settle()
    try require(reader.page?.anchorIndex == 0, "A stale direct jump replaced the latest target")
    reader.jump(to: 6); reader.cancelPageLoad(); try await settle()
    try require(reader.page?.anchorIndex == 0, "Cancelled page extraction changed the current spread")
    reader.move(.last); reader.open(fixture.appendingPathComponent("images.zip")); try await settle()
    try require(reader.source?.url == fixture.appendingPathComponent("images.zip") && reader.page?.anchorIndex == 0, "Old navigation crossed a source boundary")
    reader.open(url); try await settle(); reader.jump(to: 0); try await settle()
    reader.toggleSlideshow(); expected = reader.page
    for tick in 1...4 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await slideshow.count < tick {
            try require(ContinuousClock.now < deadline, "Streaming slideshow failed to restart its wait")
            try await Task.sleep(for: .milliseconds(1))
        }
        expected = PageNavigator.move(.next, from: expected, orientations: orientations, mode: .spread)
        await slideshow.fire(tick)
        try await Task.sleep(for: .milliseconds(10)); try await settle()
        try require(reader.page == expected, "Slideshow used incomplete archive metadata")
    }
    try require(!reader.isSlideshowPlaying && reader.page?.visibleIndices == [5, 6], "Streaming slideshow didn't stop at the final spread")
    reader.closeWindow(); await slideshow.drain()
}
