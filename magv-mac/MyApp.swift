import AppKit
import SwiftUI
import MagvCore
import UniformTypeIdentifiers

@main @MainActor struct MagvMacApp {
    static func main() {
        let app = NSApplication.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let preferences = ReaderPreferencesStore()
    lazy var session = ReaderSession(preferences: preferences)
    private var readerWindow: NSWindow?
    private var eventMonitor: Any?
    private var recentMenu: NSMenu?
    private var accessPanel: NSOpenPanel?
    private var renameSheet: RenameSheetController?
    private var transitioningFullScreen = false
    private var memoryPressure: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        session.refreshWindow = { [weak self] in self?.readerWindow?.title = self?.session.title ?? "magv" }
        session.showRenameEditor = { [weak self] in self?.presentRenameSheet() }
        session.willOpenSource = { [weak self] in self?.renameSheet?.dismiss(); self?.accessPanel?.cancel(nil) }
        session.requestDirectoryAccess = { [weak self] directory, reason, completion in
            self?.requestDirectoryAccess(directory, reason: reason, completion: completion)
        }
        session.hideCursor = { [weak self] in
            guard let window = self?.readerWindow, window.isKeyWindow,
                  let canvas = window.firstResponder as? CanvasView else { return }
            let point = canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard canvas.bounds.contains(point), point.y > 102 else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        showReader()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.readerWindow, self.readerWindow?.attachedSheet == nil,
                  !(self.readerWindow?.firstResponder is NSTextView),
                  !(self.readerWindow?.firstResponder is NSControl), self.session.canRead,
                  let action = InputRouter.action(for: event, direction: self.session.direction) else { return event }
            switch action {
            case .page(let command): self.session.move(command)
            case .source(let command): self.session.switchSource(command)
            case .rename: self.session.beginRename()
            case .addBang: self.session.addBangPrefix()
            case .search: self.searchSource(nil)
            }
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let self, let pressure else { return }
            if pressure.data.contains(.critical) { self.session.handleMemoryPressure(critical: true) }
            else if pressure.data.contains(.warning) { self.session.handleMemoryPressure(critical: false) }
            else if pressure.data.contains(.normal) { self.session.memoryPressureEnded() }
        }
        memoryPressure = pressure; pressure.resume()
        // Recovery is limited to marked, unlocked directories in the native app's dedicated cache.
        _ = try? ExtractionStorage.shared()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        showReader(); session.open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showReader(); return true
    }

    func applicationWillResignActive(_ notification: Notification) { NSCursor.setHiddenUntilMouseMoves(false) }
    func applicationWillTerminate(_ notification: Notification) {
        session.shutdown(); memoryPressure?.cancel()
        if let readerWindow { saveWindowFrame(readerWindow) }
        preferences.flush()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NSCursor.setHiddenUntilMouseMoves(false)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !session.isRenaming }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveWindowFrame(window) }
        preferences.flush(); renameSheet?.dismiss(); session.closeWindow(); NSCursor.setHiddenUntilMouseMoves(false); readerWindow = nil
    }
    func windowDidResignKey(_ notification: Notification) { NSCursor.setHiddenUntilMouseMoves(false); session.clearLoupe() }
    @objc private func willSleep() { session.suspendSlideshow() }
    @objc private func didWake() { session.resumeSlideshow() }
    func windowDidMove(_ notification: Notification) { if let window = notification.object as? NSWindow { saveWindowFrame(window) } }
    func windowDidResize(_ notification: Notification) { if let window = notification.object as? NSWindow { saveWindowFrame(window) } }
    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window = readerWindow { saveWindowFrame(window) }
        transitioningFullScreen = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) { transitioningFullScreen = false }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { transitioningFullScreen = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { transitioningFullScreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { transitioningFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        transitioningFullScreen = false
        if let window = readerWindow { saveWindowFrame(window) }
    }

    private var visibleScreenFrames: [CGRect] {
        let main = NSScreen.main
        return NSScreen.screens.sorted { $0 === main && $1 !== main }.map(\.visibleFrame)
    }
    private func saveWindowFrame(_ window: NSWindow) {
        guard window === readerWindow, !transitioningFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        preferences.setWindowFrame(window.frame)
    }
    @objc private func screensChanged() {
        guard let window = readerWindow, !window.styleMask.contains(.fullScreen), !transitioningFullScreen,
              let frame = WindowPlacement.restore(WindowFrame(window.frame), visibleFrames: visibleScreenFrames, minimumSize: window.minSize) else { return }
        window.setFrame(frame, display: true); saveWindowFrame(window)
    }

    private func showReader() {
        if let readerWindow { readerWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = session.title; window.contentMinSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(session: session, openPanel: { [weak self] in self?.openPanel(nil) }))
        window.center()
        if let saved = preferences.settings.window?.frame,
           let frame = WindowPlacement.restore(saved, visibleFrames: visibleScreenFrames, minimumSize: window.minSize) { window.setFrame(frame, display: false) }
        readerWindow = window; window.makeKeyAndOrderFront(nil); session.resumeWindow()
    }

    @objc func openPanel(_ sender: Any?) {
        showReader(); NSCursor.setHiddenUntilMouseMoves(false)
        guard let window = readerWindow else { return }
        guard !session.isRenaming, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "漫画を開く"; panel.prompt = "開く"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        let extensions = SourceFormat.imageExtensions.union(SourceFormat.archiveExtensions)
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.session.open(url) }
        }
    }

    private func requestDirectoryAccess(_ directory: URL, reason: String, completion: @escaping (URL?) -> Void) {
        showReader(); NSCursor.setHiddenUntilMouseMoves(false)
        guard let window = readerWindow, window.attachedSheet == nil else { completion(nil); return }
        let panel = NSOpenPanel(); accessPanel = panel
        panel.title = "フォルダへのアクセスを許可"
        panel.message = reason + "\n「\(directory.lastPathComponent)」フォルダを選択してください。"
        panel.prompt = "このフォルダを許可"; panel.directoryURL = directory
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.accessPanel = nil
            completion(response == .OK ? panel.url : nil)
        }
    }

    private func presentRenameSheet() {
        showReader()
        guard let window = readerWindow, window.attachedSheet == nil, let source = session.source else { session.isEditingName = false; return }
        let previous = session.sourceDestination(.previous)?.lastPathComponent
        let next = session.sourceDestination(.next)?.lastPathComponent
        let sheet = RenameSheetController(source: source, previous: previous, next: next,
            submit: { [weak self] name, completion in self?.session.renameArchive(to: name, completion: completion) },
            finished: { [weak self] in self?.session.isEditingName = false; self?.renameSheet = nil })
        renameSheet = sheet; sheet.present(on: window)
    }

    @objc private func beginRename(_ sender: Any?) { showReader(); session.beginRename() }
    @objc private func addBangPrefix(_ sender: Any?) { session.addBangPrefix() }
    @objc private func authorizeParent(_ sender: Any?) { session.authorizeParent() }
    @objc private func authorizeImageDirectory(_ sender: Any?) { session.authorizeImageDirectory() }
    @objc private func refreshSiblings(_ sender: Any?) { session.refreshNeighborhood() }
    @objc private func searchSource(_ sender: Any?) {
        guard session.canRead, let url = session.searchURL else { return }
        if !NSWorkspace.shared.open(url) { session.errorMessage = "既定ブラウザを開けませんでした。" }
    }

    @objc private func toggleLoupe(_ sender: Any?) { session.loupeEnabled.toggle() }
    @objc private func toggleSlideshow(_ sender: Any?) { session.toggleSlideshow() }
    @objc private func setInterval(_ item: NSMenuItem) {
        if let value = item.representedObject as? Double { session.setSlideshowInterval(String(value)) }
    }
    @objc private func editInterval(_ sender: Any?) { showReader(); session.isEditingInterval = true }

    private func buildMenus() {
        let main = NSMenu()
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: name); menu.delegate = self; item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target; menu.addItem(item)
        }
        let app = submenu("magv")
        add(app, "magvについて", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "magvを非表示", #selector(NSApplication.hide(_:)), key: "h")
        let hideOthers = NSMenuItem(title: "ほかを非表示", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]; app.addItem(hideOthers)
        add(app, "すべてを表示", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); add(app, "magvを終了", #selector(NSApplication.terminate(_:)), key: "q")
        let file = submenu("ファイル")
        add(file, "開く…", #selector(openPanel(_:)), key: "o", target: self)
        let recent = NSMenuItem(title: "最近使った項目", action: nil, keyEquivalent: "")
        recentMenu = NSMenu(title: "最近使った項目"); recentMenu?.delegate = self; recent.submenu = recentMenu; file.addItem(recent)
        file.addItem(.separator())
        add(file, "名前を変更…", #selector(beginRename(_:)), target: self)
        add(file, "先頭に!を追加", #selector(addBangPrefix(_:)), target: self)
        add(file, "名前をWeb検索", #selector(searchSource(_:)), target: self)
        file.addItem(.separator())
        add(file, "同階層フォルダへのアクセスを許可…", #selector(authorizeParent(_:)), target: self)
        add(file, "画像フォルダへのアクセスを許可…", #selector(authorizeImageDirectory(_:)), target: self)
        file.addItem(.separator()); add(file, "ウィンドウを閉じる", #selector(NSWindow.performClose(_:)), key: "w")
        let edit = submenu("編集")
        add(edit, "取り消す", Selector(("undo:")), key: "z")
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.addItem(redo)
        edit.addItem(.separator())
        add(edit, "切り取り", #selector(NSText.cut(_:)), key: "x"); add(edit, "コピー", #selector(NSText.copy(_:)), key: "c")
        add(edit, "貼り付け", #selector(NSText.paste(_:)), key: "v"); add(edit, "すべてを選択", #selector(NSText.selectAll(_:)), key: "a")
        let view = submenu("表示")
        for (title, mode) in [("単体", DisplayMode.single), ("見開き", .spread)] {
            let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: ""); item.target = self; item.representedObject = mode; view.addItem(item)
        }
        view.addItem(.separator())
        for (title, direction) in [("右開き", ReadingDirection.rightToLeft), ("左開き", .leftToRight)] {
            let item = NSMenuItem(title: title, action: #selector(setDirection(_:)), keyEquivalent: ""); item.target = self; item.representedObject = direction; view.addItem(item)
        }
        view.addItem(.separator())
        add(view, "ルーペ", #selector(toggleLoupe(_:)), target: self)
        add(view, "自動再生を開始", #selector(toggleSlideshow(_:)), target: self)
        let intervalItem = NSMenuItem(title: "再生間隔", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu(title: "再生間隔"); intervalMenu.delegate = self; intervalItem.submenu = intervalMenu
        for seconds in [0.5, 1, 3, 5, 10, 30] {
            let item = NSMenuItem(title: "\(seconds.formatted())秒", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = seconds; intervalMenu.addItem(item)
        }
        intervalMenu.addItem(.separator()); add(intervalMenu, "間隔を指定…", #selector(editInterval(_:)), target: self)
        view.addItem(intervalItem)
        let move = submenu("移動")
        for (title, command) in [("次ページ", PageCommand.next), ("前ページ", .previous), ("1枚次へ", .nextImage), ("1枚前へ", .previousImage), ("最初へ", .first), ("最後へ", .last)] {
            let item = NSMenuItem(title: title, action: #selector(movePage(_:)), keyEquivalent: ""); item.target = self; item.representedObject = command; move.addItem(item)
        }
        move.addItem(.separator())
        for (title, command) in [("次ソース", SourceCommand.next), ("前ソース", .previous), ("ランダムソース", .random)] {
            let item = NSMenuItem(title: title, action: #selector(switchSource(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command; move.addItem(item)
        }
        add(move, "兄弟ソースの一覧を更新", #selector(refreshSiblings(_:)), target: self)
        let window = submenu("ウィンドウ"); NSApp.windowsMenu = window
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(window, "拡大／縮小", #selector(NSWindow.performZoom(_:)))
        let fullscreen = NSMenuItem(title: "フルスクリーン", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]; window.addItem(fullscreen)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        NSCursor.setHiddenUntilMouseMoves(false)
        if menu === recentMenu {
            menu.removeAllItems()
            for url in session.recentURLs {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = url; item.toolTip = url.path; menu.addItem(item)
            }
            if menu.items.isEmpty { let item = NSMenuItem(title: "最近使った項目はありません", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        }
        for item in menu.items {
            if item.action == #selector(toggleLoupe(_:)) { item.state = session.loupeEnabled ? .on : .off }
            if item.action == #selector(toggleSlideshow(_:)) {
                item.title = session.isSlideshowPlaying ? "自動再生を停止" : "自動再生を開始"
                item.state = session.isSlideshowPlaying ? .on : .off
            }
            if let seconds = item.representedObject as? Double { item.state = seconds == session.slideshowInterval ? .on : .off }
            if item.submenu?.title == "再生間隔" { item.title = "再生間隔（\(session.slideshowInterval.formatted())秒）" }
            if let mode = item.representedObject as? DisplayMode { item.state = mode == session.mode ? .on : .off }
            if let direction = item.representedObject as? ReadingDirection { item.state = direction == session.direction ? .on : .off }
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if readerWindow?.attachedSheet != nil { return false }
        if menuItem.action == #selector(toggleLoupe(_:)) { return session.canRead }
        if menuItem.action == #selector(toggleSlideshow(_:)) { return session.isSlideshowPlaying || session.canStartSlideshow }
        if menuItem.action == #selector(editInterval(_:)) || menuItem.action == #selector(setInterval(_:)) { return readerWindow != nil && !session.isRenaming }
        if let command = menuItem.representedObject as? PageCommand { return session.canMove(command) }
        if let command = menuItem.representedObject as? SourceCommand { return session.canSwitch(command) }
        if menuItem.action == #selector(beginRename(_:)) || menuItem.action == #selector(addBangPrefix(_:)) { return session.canRename }
        if menuItem.action == #selector(searchSource(_:)) { return session.canRead && session.searchURL != nil }
        if menuItem.action == #selector(authorizeImageDirectory(_:)) { return session.canRead && session.source?.kind == .directory }
        if menuItem.action == #selector(authorizeParent(_:)) || menuItem.action == #selector(refreshSiblings(_:)) { return session.canRead }
        if menuItem.action == #selector(openPanel(_:)) { return !session.isRenaming && readerWindow?.attachedSheet == nil }
        if menuItem.action == #selector(openRecent(_:)) { return !session.isRenaming && readerWindow?.attachedSheet == nil }
        if menuItem.representedObject is DisplayMode || menuItem.representedObject is ReadingDirection { return !session.isEditingName && !session.isRenaming }
        return true
    }
    @objc private func switchSource(_ item: NSMenuItem) { if let command = item.representedObject as? SourceCommand { session.switchSource(command) } }
    @objc private func setMode(_ item: NSMenuItem) { if let mode = item.representedObject as? DisplayMode { session.mode = mode } }
    @objc private func setDirection(_ item: NSMenuItem) { if let direction = item.representedObject as? ReadingDirection { session.direction = direction } }
    @objc private func movePage(_ item: NSMenuItem) { if let command = item.representedObject as? PageCommand { session.move(command) } }
    @objc private func openRecent(_ item: NSMenuItem) { if let url = item.representedObject as? URL { showReader(); session.open(url, userSelection: false) } }
}
