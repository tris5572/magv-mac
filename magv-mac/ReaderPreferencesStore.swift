import Foundation
import MagvCore

@MainActor final class ReaderPreferencesStore {
    private let store: SettingsStore?
    private(set) var settings: ReaderSettings
    private var pendingSave: Task<Void, Never>?

    init(store: SettingsStore? = SettingsStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.tris.magv-native/settings.json"))) {
        self.store = store
        if let loaded = store?.load() { settings = loaded }
        else {
            var initial = ReaderSettings()
            if let store, !FileManager.default.fileExists(atPath: store.url.path) {
                // Migrate only this native app's earlier preferences; never read the Tauri app's settings.
                initial.displayMode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .spread
                initial.readingDirection = ReadingDirection(rawValue: UserDefaults.standard.string(forKey: "readingDirection") ?? "") ?? .rightToLeft
            }
            settings = initial
        }
    }

    func setMode(_ mode: DisplayMode) { settings.displayMode = mode; scheduleSave() }
    func setDirection(_ direction: ReadingDirection) { settings.readingDirection = direction; scheduleSave() }
    func setWindowFrame(_ frame: CGRect) {
        guard WindowFrame(frame).isValid else { return }
        settings.window = SavedWindow(frame: WindowFrame(frame)); scheduleSave()
    }
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flush()
        }
    }
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        guard let store else { return }
        do { try store.save(settings) }
        catch { NSLog("magv: 設定を保存できません: %@", error.localizedDescription) }
    }
}

@MainActor final class SessionFileAccess {
    private var selections: [String: FileAccessLease] = [:]
    private var directories: [URL] = []
    private var originals: [String: URL] = [:]
    func retain(_ url: URL, asDirectoryGrant: Bool = false) {
        if !asDirectoryGrant, selections[url.standardizedFileURL.path] != nil { return }
        let lease = FileAccessLease(url: url)
        selections[url.standardizedFileURL.path] = lease
        if asDirectoryGrant, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           !directories.contains(where: { FileAccessService.sameLocation($0, url) }) { directories.append(url) }
    }
    func covers(_ url: URL) -> Bool { directories.contains { FileAccessService.contains($0, url) } }
    func reopeningURL(for url: URL) -> URL {
        covers(url) ? url : originals[url.standardizedFileURL.path] ?? url
    }
    func remember(source: URL, selected: URL) { originals[source.standardizedFileURL.path] = selected }
    func relocate(_ old: URL, to new: URL) {
        originals.removeValue(forKey: old.standardizedFileURL.path)
        originals[new.standardizedFileURL.path] = new
    }
    func trim(to recent: [URL]) {
        let paths = Set(recent.map { $0.standardizedFileURL.path })
        originals = originals.filter { paths.contains($0.key) }
        let originalPaths = Set(originals.values.map { $0.standardizedFileURL.path })
        let roots = directories.filter { root in recent.contains { FileAccessService.contains(root, $0) } }
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        selections = selections.filter { paths.contains($0.key) || originalPaths.contains($0.key) || rootPaths.contains($0.key) }
        directories = roots
    }
}
