import AppKit
import MagvCore

@main struct BookmarkSmoke {
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--restore" {
            try await restoreInNewProcess(directory: URL(fileURLWithPath: arguments[1]), storeURL: URL(fileURLWithPath: arguments[2]))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("magv-bookmarks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: arguments[0]).appendingPathComponent("images.zip")
        for name in ["a.zip", "b.zip"] { try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent(name)) }
        try persistenceAndRecovery(root: root, directory: directory)
        if arguments.contains("--bookmarks") {
            let store = DirectoryBookmarkStore(url: root.appendingPathComponent("real/folder-bookmarks.json"))
            do {
                let access = SessionFileAccess(bookmarkStore: store)
                access.retain(directory, asDirectoryGrant: true)
                try require(store.load().count == 1, "Security-scoped bookmark was not saved")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--restore", directory.path, store.url.path]
            try process.run(); process.waitUntilExit()
            try require(process.terminationStatus == 0, "Bookmark restoration in a new process failed")
        }
        print("Directory bookmark smoke passed: persistence, deduplication, lazy restore after trim, stale refresh, invalid/missing grants, recovery")
    }

    @MainActor private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "BookmarkSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor private static func persistenceAndRecovery(root: URL, directory: URL) throws {
        // Deterministic failure and stale-data cases run without ScopedBookmarksAgent.
        let codec = DirectoryBookmarkCodec(create: { Data($0.absoluteString.utf8) }, resolve: { data in
            guard let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.isFileURL else {
                throw ReaderError.permission
            }
            return (url, false)
        })
        let store = DirectoryBookmarkStore(url: root.appendingPathComponent("fake/folder-bookmarks.json"))
        let archive = directory.appendingPathComponent("a.zip")
        do {
            let access = SessionFileAccess(bookmarkStore: store, bookmarkCodec: codec)
            access.retain(archive, asDirectoryGrant: true)
            try require(store.load().isEmpty && !access.covers(directory), "A selected file persisted a parent folder grant")
            access.retain(directory, asDirectoryGrant: true)
            access.retain(directory, asDirectoryGrant: true)
            try require(store.load().count == 1, "Repeated folder selection duplicated the bookmark")
        }
        let restored = SessionFileAccess(bookmarkStore: store, bookmarkCodec: codec)
        try require(restored.covers(archive) && restored.covers(directory.appendingPathComponent("b.zip")), "Saved folder did not cover sibling archives")
        restored.trim(to: [])
        try require(restored.covers(archive) && store.load().count == 1, "Trimming active leases discarded the saved grant")
        let outside = root.appendingPathComponent("books-other", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try require(!restored.covers(outside) && !restored.covers(root) && !restored.covers(link.appendingPathComponent("other.zip")), "Restored grant escaped its folder boundary")

        let invalid = Data("invalid".utf8), stale = Data("stale".utf8)
        let missing = try codec.create(root.appendingPathComponent("disconnected", isDirectory: true))
        var staleCodec = codec
        staleCodec.resolve = { data in data == stale ? (directory, true) : try codec.resolve(data) }
        try store.save([invalid, missing, stale])
        let refreshed = SessionFileAccess(bookmarkStore: store, bookmarkCodec: staleCodec)
        try require(refreshed.covers(archive), "Invalid or missing bookmark blocked a valid stale grant")
        try require(store.load() == [invalid, missing, try codec.create(directory)], "Stale bookmark was not refreshed, or unavailable grants were deleted")
        var failingCodec = staleCodec
        failingCodec.create = { _ in throw ReaderError.permission }
        try store.save([stale])
        try require(SessionFileAccess(bookmarkStore: store, bookmarkCodec: failingCodec).covers(archive), "Refresh failure discarded a usable grant")
        try require(store.load() == [stale], "Failed refresh overwrote the last saved bookmark")
        try store.save([invalid, missing, try codec.create(archive)])
        try require(!SessionFileAccess(bookmarkStore: store, bookmarkCodec: codec).covers(directory), "Invalid, missing, or file bookmarks granted folder access")

        let preferences = ReaderPreferencesStore(store: SettingsStore(url: store.url.deletingLastPathComponent().appendingPathComponent("settings.json")))
        preferences.setMode(.single); preferences.flush()
        try Data("damaged JSON".utf8).write(to: store.url)
        let recovered = SessionFileAccess(bookmarkStore: store, bookmarkCodec: codec)
        try require(!recovered.covers(archive) && preferences.settings.displayMode == .single, "Corrupt bookmark storage granted access or affected preferences")
        recovered.retain(directory, asDirectoryGrant: true)
        try require(store.load().count == 1, "Selecting a folder did not repair corrupt bookmark storage")
        let unwritable = DirectoryBookmarkStore(url: outside) // Existing directory cannot be replaced by an atomic file write.
        let temporary = SessionFileAccess(bookmarkStore: unwritable, bookmarkCodec: codec)
        temporary.retain(directory, asDirectoryGrant: true)
        try require(temporary.covers(archive), "Save failure prevented use of the current folder grant")
    }

    @MainActor private static func restoreInNewProcess(directory: URL, storeURL: URL) async throws {
        // Use the production Foundation codec and a fresh ReaderSession/preferences store.
        let preferences = ReaderPreferencesStore(store: SettingsStore(url: storeURL.deletingLastPathComponent().appendingPathComponent("settings.json")))
        let reader = ReaderSession(preferences: preferences)
        defer { reader.shutdown() }
        var prompts = 0
        reader.requestDirectoryAccess = { _, _, completion in prompts += 1; completion(nil) }
        func settle() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while reader.isLoading || reader.isRendering || reader.isSelectingSource || reader.isRenaming {
                try require(ContinuousClock.now < deadline, "Bookmark-backed navigation timed out")
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(reader.errorMessage == nil, reader.errorMessage ?? "Reader error")
        }
        let first = directory.appendingPathComponent("a.zip"), second = directory.appendingPathComponent("b.zip")
        reader.open(first); try await settle()
        reader.authorizeParent(); try await settle()
        reader.switchSource(.next); try await settle()
        try require(FileAccessService.sameLocation(reader.source!.url, second), "Restored grant did not allow the next archive")
        reader.switchSource(.previous); try await settle()
        try require(FileAccessService.sameLocation(reader.source!.url, first), "Restored grant did not allow the previous archive")
        reader.beginRename(); try await settle()
        try require(reader.isEditingName && prompts == 0, "Restored grant asked for folder permission again")
        reader.isEditingName = false
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            reader.renameArchive(to: "renamed") { continuation.resume(returning: $0) }
        }
        try result.get(); try await settle()
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed.zip").path), "Restored grant lost write access")
        print("Real security-scoped bookmark smoke passed: new process, previous/next archive, rename, zero folder prompts")
    }
}
