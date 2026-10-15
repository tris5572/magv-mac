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
    let session = ReaderSession()
    private var readerWindow: NSWindow?
    private var eventMonitor: Any?
    private var recentMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        session.refreshWindow = { [weak self] in self?.readerWindow?.title = self?.session.title ?? "magv" }
        session.hideCursor = { [weak self] in
            guard let window = self?.readerWindow, window.isKeyWindow,
                  let canvas = window.firstResponder as? CanvasView else { return }
            let point = canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard canvas.bounds.contains(point), point.y > 66 else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        showReader()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.readerWindow, self.readerWindow?.attachedSheet == nil,
                  !(self.readerWindow?.firstResponder is NSTextView),
                  !(self.readerWindow?.firstResponder is NSControl), self.session.canRead,
                  let command = InputRouter.command(for: event, direction: self.session.direction) else { return event }
            self.session.move(command)
            return nil
        }
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
        session.cancelOpen()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        NSCursor.setHiddenUntilMouseMoves(false)
    }
    func windowWillClose(_ notification: Notification) { session.cancelOpen(); NSCursor.setHiddenUntilMouseMoves(false); readerWindow = nil }
    func windowDidResignKey(_ notification: Notification) { NSCursor.setHiddenUntilMouseMoves(false) }

    private func showReader() {
        if let readerWindow { readerWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = session.title; window.minSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(session: session, openPanel: { [weak self] in self?.openPanel(nil) }))
        window.center(); readerWindow = window; window.makeKeyAndOrderFront(nil)
    }

    @objc func openPanel(_ sender: Any?) {
        showReader(); NSCursor.setHiddenUntilMouseMoves(false)
        guard let window = readerWindow else { return }
        let panel = NSOpenPanel()
        panel.title = "漫画を開く"; panel.prompt = "開く"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        let extensions = SourceFormat.imageExtensions.union(SourceFormat.archiveExtensions)
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.session.open(url) }
        }
    }

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
        let move = submenu("移動")
        for (title, command) in [("次ページ", PageCommand.next), ("前ページ", .previous), ("1枚次へ", .nextImage), ("1枚前へ", .previousImage), ("最初へ", .first), ("最後へ", .last)] {
            let item = NSMenuItem(title: title, action: #selector(movePage(_:)), keyEquivalent: ""); item.target = self; item.representedObject = command; move.addItem(item)
        }
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
            if let mode = item.representedObject as? DisplayMode { item.state = mode == session.mode ? .on : .off }
            if let direction = item.representedObject as? ReadingDirection { item.state = direction == session.direction ? .on : .off }
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let command = menuItem.representedObject as? PageCommand { return session.canMove(command) }
        return true
    }
    @objc private func setMode(_ item: NSMenuItem) { if let mode = item.representedObject as? DisplayMode { session.mode = mode } }
    @objc private func setDirection(_ item: NSMenuItem) { if let direction = item.representedObject as? ReadingDirection { session.direction = direction } }
    @objc private func movePage(_ item: NSMenuItem) { if let command = item.representedObject as? PageCommand { session.move(command) } }
    @objc private func openRecent(_ item: NSMenuItem) { if let url = item.representedObject as? URL { showReader(); session.open(url) } }
}
