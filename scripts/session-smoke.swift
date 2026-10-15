import AppKit
import MagvCore

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
        let session = ReaderSession()
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "SessionSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitForOpen() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while session.isLoading || session.isRendering {
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
        print("Session smoke passed: latest request, cancellation, failure retention, history, recent items, direct image, direction keys")
    }
}
