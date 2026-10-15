import AppKit
import MagvCore
import Observation

@MainActor @Observable final class ReaderSession {
    var source: LoadedSource?
    var page: DisplayPage?
    var decoded: [Int: DecodedImage] = [:]
    var imageFailures: [Int: String] = [:]
    var isLoading = false
    var isRendering = false
    var loadingMessage = "読み込み中…"
    var errorMessage: String? {
        didSet { if errorMessage != nil { NSCursor.setHiddenUntilMouseMoves(false) } }
    }
    var mode: DisplayMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "displayMode"); recalculate() }
    }
    var direction: ReadingDirection {
        didSet { UserDefaults.standard.set(direction.rawValue, forKey: "readingDirection"); refreshWindow?() }
    }
    var recentURLs: [URL] = []
    var refreshWindow: (() -> Void)?
    var hideCursor: (() -> Void)?
    private var positions: [URL: Int] = [:]
    private var openTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var requestID = UUID()
    private var renderID = UUID()
    private let cache = ImageCache()
    private var pixelSize = 2048

    init() {
        mode = DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .spread
        direction = ReadingDirection(rawValue: UserDefaults.standard.string(forKey: "readingDirection") ?? "") ?? .rightToLeft
    }

    var orientations: [ImageOrientation] {
        source?.images.enumerated().map { imageFailures[$0.offset] == nil ? $0.element.orientation : .unknown } ?? []
    }
    var title: String { source?.title ?? "magv" }
    var canRead: Bool { source != nil && !isLoading }
    var pageLabel: String { guard let source, let page else { return "- / -" }; return "\(page.anchorIndex + 1) / \(source.images.count)" }

    func canMove(_ command: PageCommand) -> Bool {
        guard canRead else { return false }
        return PageNavigator.move(command, from: page, orientations: orientations, mode: mode) != page
    }

    func open(_ url: URL) {
        openTask?.cancel()
        let id = UUID(); requestID = id
        isLoading = true; loadingMessage = "\(url.lastPathComponent)を読み込み中…"; errorMessage = nil
        let reportProgress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == id, self.isLoading else { return }
                self.loadingMessage = message
            }
        }
        openTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try SourceLoader.load(url, progress: reportProgress)
            }
            do {
                let loaded = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.rememberPosition()
                let index = loaded.initialIndex ?? self.positions[loaded.url] ?? 0
                self.source = loaded; self.imageFailures = [:]; self.decoded = [:]
                self.page = PageNavigator.page(at: index, orientations: loaded.images.map(\.orientation), mode: self.mode)
                self.recentURLs.removeAll { $0 == loaded.url }; self.recentURLs.insert(loaded.url, at: 0)
                self.recentURLs = Array(self.recentURLs.prefix(20))
                self.isLoading = false; self.rememberPosition(); self.refreshWindow?(); self.render(); self.hideCursor?()
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }; self.isLoading = false
            } catch {
                guard let self, self.requestID == id else { return }
                self.isLoading = false; self.errorMessage = "\(url.lastPathComponent)\n\(error.localizedDescription)"
            }
        }
    }

    func cancelOpen() { requestID = UUID(); openTask?.cancel(); isLoading = false }

    func move(_ command: PageCommand) {
        guard canRead else { return }
        let next = PageNavigator.move(command, from: page, orientations: orientations, mode: mode)
        guard next != page else { return }
        page = next; rememberPosition(); render(); hideCursor?()
    }

    func jump(to index: Int) {
        guard canRead else { return }
        page = PageNavigator.page(at: index, orientations: orientations, mode: mode)
        rememberPosition(); render(); hideCursor?()
    }

    func updatePixelSize(_ size: Int) {
        let bucket = max(1024, min(8192, ((size + 511) / 512) * 512))
        guard bucket != pixelSize else { return }; pixelSize = bucket; render()
    }

    private func rememberPosition() { if let source, let page { positions[source.url] = page.anchorIndex } }
    private func recalculate() {
        guard let page else { return }
        self.page = PageNavigator.page(at: page.anchorIndex, orientations: orientations, mode: mode); render()
    }

    private func render() {
        renderTask?.cancel()
        let id = UUID(); renderID = id
        guard let source, let page else { return }
        let indices = page.visibleIndices; let pixels = pixelSize
        isRendering = true; decoded = decoded.filter { indices.contains($0.key) }
        renderTask = Task { [weak self, cache] in
            var result: [Int: DecodedImage] = [:]; var failures: [Int: String] = [:]
            for index in indices {
                guard !Task.isCancelled else { return }
                let entry = source.images[index]
                if let failure = entry.failure { failures[index] = failure; continue }
                do { result[index] = try await cache.image(at: entry.fileURL, maxPixelSize: pixels) }
                catch { failures[index] = error.localizedDescription }
            }
            guard !Task.isCancelled, let self, self.renderID == id else { return }
            self.decoded = result; self.imageFailures.merge(failures) { _, new in new }; self.isRendering = false
            if !failures.isEmpty {
                let revised = PageNavigator.page(at: page.anchorIndex, orientations: self.orientations, mode: self.mode, forceSingle: page.forceSingle)
                if revised != self.page { self.page = revised; self.render() }
            }
        }
    }
}
