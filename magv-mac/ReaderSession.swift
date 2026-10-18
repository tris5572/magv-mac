import AppKit
import MagvCore
import Observation

/// 描画に必要なページ情報と画像をまとめた、準備済みの表示状態。
struct PresentedPage {
    var sourceURL: URL
    let page: DisplayPage
    let images: [Int: DecodedImage]
    let failureNames: [Int: String]
}

/// 閲覧操作の窓口。読み込み・ページ移動・描画・先読みを連携させ、UIへ状態を公開する。
/// UIの状態更新をメインアクターに集約し、展開やデコードは専用の処理へ委譲する。
@MainActor @Observable final class ReaderSession {
    var source: LoadedSource?
    var page: DisplayPage?
    // 移動先の page と、実際に描画する presentedPage を分け、準備中も直前の画面を維持する。
    private(set) var presentedPage: PresentedPage?
    var decoded: [Int: DecodedImage] { presentedPage?.images ?? [:] }
    var imageFailures: [Int: String] = [:]
    var isSlideshowPlaying = false
    private(set) var slideshowInterval = SlideshowInterval.initial
    var loupeEnabled = false { didSet { if !loupeEnabled { clearLoupe() } } }
    private(set) var loupeIndex: Int?
    private(set) var loupeImage: DecodedImage?
    var isLoading = false
    private var isDecoding = false
    private(set) var isPreparingPage = false
    var isRendering: Bool { isDecoding || isPreparingPage }
    var isSelectingSource = false
    var isRenaming = false
    var isEditingName = false
    var isEditingInterval = false {
        didSet { if isEditingInterval { cancelSlideshowWait() } else { scheduleSlideshow() } }
    }
    var siblings: [URL] = []
    var needsParentAccess = false
    var errorTitle = "操作できませんでした"
    var loadingMessage = "読み込み中…"
    var errorMessage: String? {
        didSet { if errorMessage != nil { NSCursor.setHiddenUntilMouseMoves(false) } }
    }
    var mode: DisplayMode {
        didSet { preferences.setMode(mode); recalculate() }
    }
    var direction: ReadingDirection {
        didSet { preferences.setDirection(direction); clearLoupe(); refreshWindow?(); scheduleSlideshow() }
    }
    var recentURLs: [URL] = []
    var refreshWindow: (() -> Void)?
    var hideCursor: (() -> Void)?
    var showRenameEditor: (() -> Void)?
    var willOpenSource: (() -> Void)?
    var requestDirectoryAccess: ((URL, String, @escaping (URL?) -> Void) -> Void)?
    let preferences: ReaderPreferencesStore
    private let fileAccess: SessionFileAccess
    private let temporaryRoot: URL?
    private let sourceCache: SourceCache
    private let wait: @Sendable (Duration) async throws -> Void
    private var slideshowTask: Task<Void, Never>?
    // 各処理のIDは要求の世代を表す。キャンセル後に完了した古い処理の反映を防ぐ。
    private var slideshowID = UUID()
    private var slideshowSuspended = false
    private var prefetchTask: Task<Void, Never>?
    private var prefetchID = UUID()
    private var prefetchForward = true
    private var loupeTask: Task<Void, Never>?
    private var loupeID = UUID()
    private var loupePixels = 0
    private var suppressPrefetch = false
    private var windowIsOpen = true
    // 閲覧位置と最近使った項目は起動中だけ保持し、設定ファイルには保存しない。
    private var positions: [URL: Int] = [:]
    private struct ArchiveNeighbors { let previous: URL?; let next: URL? }
    // 開くたびに、その時点の隣接ソースを記録する。過去の名前変更による移動先を引き継がない。
    private var archiveNeighbors: ArchiveNeighbors?
    private var openTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private enum Navigation { case command(PageCommand), index(Int) }
    private var navigationTask: Task<Void, Never>?
    private var navigationID = UUID()
    private var navigationQueue: [Navigation] = []
    private var neighborhoodTask: Task<Void, Never>?
    private var renameTask: Task<Void, Never>?
    private var deferredOpen: (url: URL, userSelection: Bool)?
    private var requestID = UUID()
    private var renderID = UUID()
    private let cache: ImageCache
    private var pixelSize = 2048

    init(preferences: ReaderPreferencesStore = ReaderPreferencesStore(), temporaryRoot: URL? = nil,
         imageCache: ImageCache = ImageCache(),
         wait: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.preferences = preferences
        self.temporaryRoot = temporaryRoot
        cache = imageCache
        fileAccess = SessionFileAccess(bookmarkStore: preferences.directoryBookmarkStore)
        sourceCache = SourceCache(temporaryRoot: temporaryRoot)
        self.wait = wait
        mode = preferences.settings.displayMode
        direction = preferences.settings.readingDirection
    }

    var orientations: [ImageOrientation] {
        source?.images.enumerated().map { imageFailures[$0.offset] == nil ? $0.element.orientation : .unknown } ?? []
    }
    var title: String { source?.title ?? "magv" }
    var canRead: Bool { windowIsOpen && source != nil && !isLoading && !isRenaming && !isEditingName && !isEditingInterval && !isSelectingSource }
    var canRename: Bool { canRead && !isPreparingPage && source?.kind == .archive }
    var searchURL: URL? { source.flatMap { SourceSearch.url(for: $0.url, kind: $0.kind) } }
    var pageLabel: String { guard let source, let page else { return "- / -" }; return "\(page.anchorIndex + 1) / \(source.images.count)" }

    func canMove(_ command: PageCommand) -> Bool {
        guard canRead else { return false }
        return PageNavigator.move(command, from: page, orientations: orientations, mode: mode) != page
    }

    /// 新しいソースを準備し、成功した時点で現在の本を置き換える。失敗時は元の表示を保つ。
    func open(_ url: URL, userSelection: Bool = true) {
        // ファイル名変更の途中では切り替えず、変更結果に合わせたURLで後から開く。
        if isRenaming { deferredOpen = (url, userSelection); return }
        stopSlideshow(); cancelNavigation(); cancelPrefetch(exceptSource: url); clearLoupe()
        prefetchForward = true
        willOpenSource?(); isEditingName = false; isEditingInterval = false
        fileAccess.retain(url, asDirectoryGrant: userSelection)
        let inputURL = userSelection ? url : fileAccess.reopeningURL(for: url)
        neighborhoodTask?.cancel(); isSelectingSource = false
        openTask?.cancel()
        let id = UUID(); requestID = id
        isLoading = true; loadingMessage = "\(url.lastPathComponent)を読み込み中…"; errorMessage = nil
        let reportProgress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == id, self.isLoading else { return }
                self.loadingMessage = message
            }
        }
        let hint = positions[inputURL.resolvingSymlinksInPath().standardizedFileURL] ?? 0
        openTask = Task { [weak self, sourceCache] in
            await sourceCache.cancelLoads(except: inputURL)
            do {
                let loaded = try await sourceCache.load(inputURL, initialIndex: hint, mode: self?.mode ?? .spread, progress: reportProgress)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.rememberPosition()
                // 直接選択した画像を最優先し、それ以外は起動中に記録した閲覧位置から再開する。
                let remembered = (userSelection ? loaded.initialIndex : nil) ?? self.positions[loaded.url] ?? 0
                let index = min(max(0, remembered), loaded.images.count - 1)
                let prepared = try await loaded.preparingPage(at: index, mode: self.mode)
                // 先読み・キャッシュに残る一覧が名前変更前の可能性があるため、アーカイブの兄弟一覧を取り直す。
                let urls = prepared.kind == .archive
                    ? try? await Task.detached { try FileAccessService.siblings(of: prepared.url, kind: prepared.kind) }.value
                    : (prepared.needsParentAccess ? nil : prepared.siblings)
                guard !Task.isCancelled, self.requestID == id else { return }
                self.cancelNavigation()
                self.source = prepared; self.imageFailures = [:]
                self.archiveNeighbors = nil; self.updateNeighborhood(urls, for: prepared)
                self.page = PageNavigator.page(at: index, orientations: prepared.images.map(\.orientation), mode: self.mode)
                self.recentURLs.removeAll { $0 == loaded.url }; self.recentURLs.insert(loaded.url, at: 0)
                self.recentURLs = Array(self.recentURLs.prefix(20))
                self.fileAccess.remember(source: loaded.url, selected: inputURL)
                self.fileAccess.trim(to: self.recentURLs)
                self.isLoading = false; self.rememberPosition(); self.refreshWindow?(); self.render(); self.hideCursor?()
                self.refreshNeighborhood()
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }
                self.isLoading = false; self.fileAccess.trim(to: self.recentURLs)
            } catch {
                guard let self, self.requestID == id else { return }
                self.isLoading = false; self.errorTitle = "開けませんでした"
                self.errorMessage = "\(url.lastPathComponent)\n\(error.localizedDescription)"
                self.fileAccess.trim(to: self.recentURLs)
                self.refreshNeighborhood()
            }
        }
    }

    func cancelOpen() {
        stopSlideshow(); cancelNavigation(); cancelPrefetch()
        requestID = UUID(); openTask?.cancel(); neighborhoodTask?.cancel()
        Task { [sourceCache] in await sourceCache.cancelLoads() }
        isLoading = false; isSelectingSource = false
        fileAccess.trim(to: recentURLs)
    }

    func canSwitch(_ command: SourceCommand) -> Bool {
        guard canRead, !needsParentAccess, let source else { return false }
        if command == .random { return siblings.contains { !FileAccessService.sameLocation($0, source.url) } }
        guard let destination = sourceDestination(command) else { return false }
        return siblings.contains { FileAccessService.sameLocation($0, destination) }
    }

    /// アーカイブの前後移動には、開いた時点で確定した隣接URLを使う。
    func sourceDestination(_ command: SourceCommand) -> URL? {
        guard let source else { return nil }
        if source.kind == .archive, let archiveNeighbors {
            switch command {
            case .previous: return archiveNeighbors.previous
            case .next: return archiveNeighbors.next
            case .random: break
            }
        }
        return SourceNavigator.destination(command, current: source.url, siblings: siblings)
    }

    func switchSource(_ command: SourceCommand) {
        guard canRead, let source else { return }
        stopSlideshow()
        errorTitle = "ソースを切り替えられませんでした"
        if needsParentAccess {
            authorizeParent { [weak self] in self?.switchSource(command) }
            return
        }
        // 一覧更新で並び順が変わっても、予定していた移動先が消えた場合は別の本へ進めない。
        let planned = sourceDestination(command)
        let id = requestID
        neighborhoodTask?.cancel(); isSelectingSource = true
        neighborhoodTask = Task { [weak self] in
            do {
                let urls = try await Task.detached { try FileAccessService.siblings(of: source.url, kind: source.kind) }.value
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.updateNeighborhood(urls, for: source); self.isSelectingSource = false
                if command != .random, let planned, !urls.contains(where: { FileAccessService.sameLocation($0, planned) }) {
                    self.errorMessage = "\(planned.lastPathComponent)が見つかりません。兄弟ソースの一覧を更新しました。"; return
                }
                if let next = self.sourceDestination(command) { self.open(next, userSelection: false) }
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.isSelectingSource = false; self.needsParentAccess = true
                self.errorMessage = "同階層のソースを確認できません。\n\(error.localizedDescription)"
            }
        }
    }

    private func updateNeighborhood(_ urls: [URL]?, for source: LoadedSource) {
        siblings = urls ?? [source.url]; needsParentAccess = urls == nil
        if source.kind == .archive, archiveNeighbors == nil, let urls {
            archiveNeighbors = ArchiveNeighbors(
                previous: SourceNavigator.destination(.previous, current: source.url, siblings: urls),
                next: SourceNavigator.destination(.next, current: source.url, siblings: urls))
        }
    }

    func authorizeDirectory(_ url: URL) { fileAccess.retain(url, asDirectoryGrant: true); needsParentAccess = false }

    func authorizeParent(then action: (() -> Void)? = nil) {
        guard let source else { return }
        requestAccess(to: source.url.deletingLastPathComponent(),
                      reason: "同階層のソースの切替や名前の変更には、このフォルダへのアクセスが必要です。") { [weak self] in
            self?.needsParentAccess = false
            if let action { action() } else { self?.refreshNeighborhood() }
        }
    }

    func authorizeImageDirectory() {
        guard let source, source.kind == .directory else { return }
        let anchorURL = source.images[page?.anchorIndex ?? 0].fileURL
        requestAccess(to: source.url, reason: "フォルダ内の画像をすべて表示するには、このフォルダへのアクセスが必要です。") { [weak self] in
            self?.open(anchorURL)
        }
    }

    /// フォルダの許可取得後、要求元の本がまだ表示中であることを確認して操作を再開する。
    private func requestAccess(to directory: URL, reason: String, then action: @escaping () -> Void) {
        errorTitle = "フォルダへのアクセスを確認できませんでした"
        if fileAccess.covers(directory) { action(); return }
        guard let requestDirectoryAccess else { errorMessage = ReaderError.permission.localizedDescription; return }
        let expected = source?.url
        let id = requestID
        NSCursor.setHiddenUntilMouseMoves(false)
        requestDirectoryAccess(directory, reason) { [weak self] selected in
            guard let self, self.requestID == id, self.source?.url == expected, !self.isLoading, let selected else { return }
            let lease = FileAccessLease(url: selected)
            guard FileAccessService.sameLocation(selected.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath()) else {
                self.errorMessage = "「\(directory.lastPathComponent)」フォルダを選択してください。"; return
            }
            self.authorizeDirectory(selected)
            withExtendedLifetime(lease) { action() }
        }
    }

    func refreshNeighborhood() {
        guard let source, !isLoading, !isRenaming else { return }
        let id = requestID
        neighborhoodTask?.cancel()
        neighborhoodTask = Task { [weak self] in
            let urls = try? await Task.detached { try FileAccessService.siblings(of: source.url, kind: source.kind) }.value
            guard !Task.isCancelled, let self, self.requestID == id, self.source?.url == source.url else { return }
            self.updateNeighborhood(urls, for: source)
            self.prefetch()
        }
    }

    func beginRename() {
        guard canRename else { return }
        stopSlideshow(); cancelPrefetch()
        authorizeParent { [weak self] in
            guard let self, self.canRename, let source = self.source else { return }
            let id = self.requestID
            self.isSelectingSource = true; self.neighborhoodTask?.cancel()
            self.neighborhoodTask = Task { [weak self] in
                let urls = try? await Task.detached { try FileAccessService.siblings(of: source.url, kind: source.kind) }.value
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.updateNeighborhood(urls, for: source); self.isSelectingSource = false
                self.isEditingName = true; NSCursor.setHiddenUntilMouseMoves(false); self.showRenameEditor?()
            }
        }
    }

    func addBangPrefix() {
        guard canRename, let source else { return }
        stopSlideshow(); cancelPrefetch()
        authorizeParent { [weak self] in
            self?.renameArchive(to: "!" + source.url.deletingPathExtension().lastPathComponent) { result in
                if case .failure(let error) = result {
                    self?.errorTitle = "名前を変更できませんでした"; self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 実ファイルを変更し、表示・履歴・キャッシュ・保留中の要求が参照するURLを揃える。
    func renameArchive(to baseName: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let source, source.kind == .archive, !isLoading, !isRenaming,
              fileAccess.covers(source.url.deletingLastPathComponent()) else { completion(.failure(ReaderError.permission)); return }
        do { try FileAccessService.validateBaseName(baseName) } catch { completion(.failure(error)); return }
        stopSlideshow(); cancelPrefetch()
        cancelNavigation()
        isRenaming = true
        renameTask = Task { [weak self] in
            let result = await Task.detached {
                Result { try FileAccessService.renameArchive(at: source.url, baseName: baseName, expectedRevision: source.revision) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let newURL):
                self.rememberPosition()
                if !FileAccessService.sameLocation(newURL, source.url) {
                    self.source = source.relocated(to: newURL)
                    if self.presentedPage?.sourceURL == source.url { self.presentedPage?.sourceURL = newURL }
                    if let renamed = self.source { await self.sourceCache.relocate(renamed, from: source.url) }
                    self.fileAccess.retain(newURL)
                    self.fileAccess.relocate(source.url, to: newURL)
                    self.positions[newURL] = self.positions.removeValue(forKey: source.url)
                    self.recentURLs = self.recentURLs.map { FileAccessService.sameLocation($0, source.url) ? newURL : $0 }
                    var seen = Set<URL>(); self.recentURLs = self.recentURLs.filter { seen.insert($0).inserted }
                    self.siblings = self.siblings.map { FileAccessService.sameLocation($0, source.url) ? newURL : $0 }
                        .sorted { SourceFormat.naturalOrder($0.lastPathComponent, $1.lastPathComponent) }
                    self.fileAccess.trim(to: self.recentURLs)
                    if let deferred = self.deferredOpen, FileAccessService.sameLocation(deferred.url, source.url) {
                        self.deferredOpen = (newURL, deferred.userSelection)
                    }
                    self.refreshWindow?()
                }
                self.isRenaming = false
                completion(.success(())); self.refreshNeighborhood()
            case .failure(let error): self.isRenaming = false; completion(.failure(error)); self.refreshNeighborhood()
            }
            if let pending = self.deferredOpen { self.deferredOpen = nil; self.open(pending.url, userSelection: pending.userSelection) }
        }
    }

    func move(_ command: PageCommand) {
        guard canRead else { return }
        prefetchForward = command != .previous && command != .previousImage && command != .last
        if source?.archive == nil {
            let next = PageNavigator.move(command, from: page, orientations: orientations, mode: mode)
            guard next != page else { scheduleSlideshow(); return }
            page = next; rememberPosition(); render(); hideCursor?(); return
        }
        enqueue(.command(command))
    }

    func jump(to index: Int) {
        guard canRead else { return }
        prefetchForward = index >= (page?.anchorIndex ?? 0)
        cancelNavigation()
        if source?.archive == nil {
            page = PageNavigator.page(at: index, orientations: orientations, mode: mode)
            rememberPosition(); render(); hideCursor?(); return
        }
        enqueue(.index(index))
    }

    func cancelPageLoad() { stopSlideshow(); cancelNavigation() }
    private func cancelNavigation() {
        navigationID = UUID(); navigationTask?.cancel(); navigationTask = nil
        navigationQueue.removeAll(); isPreparingPage = false
    }
    /// アーカイブのページ移動を順番に処理し、連続入力でも相対移動の順序を保つ。
    private func enqueue(_ request: Navigation) {
        cancelSlideshowWait(); cancelPrefetch(finishingCurrentImage: true, exceptSource: source?.url); clearLoupe()
        navigationQueue.append(request)
        guard navigationTask == nil else { return }
        let id = navigationID; isPreparingPage = true
        navigationTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.navigationID == id, !self.navigationQueue.isEmpty {
                let request = self.navigationQueue.removeFirst()
                guard let current = self.source, let previous = self.page else { break }
                do {
                    let needed: [Int]
                    switch request {
                    case .index(let index):
                        let anchor = min(max(0, index), current.images.count - 1); needed = self.mode == .spread ? [anchor, anchor + 1] : [anchor]
                    case .command(let command):
                        switch command {
                        case .next: let next = (previous.visibleIndices.last ?? previous.anchorIndex) + 1; needed = self.mode == .spread ? [next, next + 1] : [next]
                        case .nextImage: needed = self.mode == .spread ? [previous.anchorIndex + 1, previous.anchorIndex + 2] : [previous.anchorIndex + 1]
                        case .previous: needed = self.mode == .spread ? [previous.anchorIndex - 2, previous.anchorIndex - 1, previous.anchorIndex] : [previous.anchorIndex - 1]
                        case .previousImage: needed = self.mode == .spread ? [previous.anchorIndex - 1, previous.anchorIndex] : [previous.anchorIndex - 1]
                        case .first: needed = self.mode == .spread ? [0, 1] : [0]
                        case .last: needed = self.mode == .spread ? [current.images.count - 2, current.images.count - 1] : [current.images.count - 1]
                        }
                    }
                    // 移動候補の縦横を先に調べて見開きを判定し、表示が決まった画像のファイルを保持する。
                    let metadata = try await current.preparingMetadata(at: needed)
                    guard !Task.isCancelled, self.navigationID == id else { return }
                    let orientations = metadata.images.enumerated().map { self.imageFailures[$0.offset] == nil ? $0.element.orientation : .unknown }
                    let next: DisplayPage?
                    switch request {
                    case .index(let index): next = PageNavigator.page(at: index, orientations: orientations, mode: self.mode)
                    case .command(let command): next = PageNavigator.move(command, from: previous, orientations: orientations, mode: self.mode)
                    }
                    guard let next else { continue }
                    if case .command = request, next == previous { self.source = metadata; continue }
                    let prepared = try await metadata.preparingImages(at: next.visibleIndices)
                    guard !Task.isCancelled, self.navigationID == id else { return }
                    self.source = prepared; self.page = next; self.rememberPosition(); self.render(); self.hideCursor?()
                } catch is CancellationError { if Task.isCancelled { return } }
                catch {
                    guard !Task.isCancelled, self.navigationID == id else { return }
                    self.navigationQueue.removeAll(); self.stopSlideshow()
                    self.errorTitle = "ページを読み込めませんでした"; self.errorMessage = error.localizedDescription
                }
            }
            guard let self, self.navigationID == id else { return }
            self.navigationTask = nil; self.isPreparingPage = false
            if !self.isDecoding { self.scheduleSlideshow(); self.prefetch() }
        }
    }

    // 512px単位に切り上げ、ウィンドウの細かなリサイズによる再デコードを抑える。
    func updatePixelSize(_ size: Int) {
        let bucket = max(1024, min(8192, ((size + 511) / 512) * 512))
        guard bucket != pixelSize else { return }; pixelSize = bucket; render()
    }

    private func rememberPosition() { if let source, let page { positions[source.url] = page.anchorIndex } }
    private func recalculate() {
        guard let page else { return }
        cancelNavigation()
        if source?.archive == nil {
            self.page = PageNavigator.page(at: page.anchorIndex, orientations: orientations, mode: mode); render()
        } else { enqueue(.index(page.anchorIndex)) }
    }

    /// 表示対象をデコードし、全枠の画像またはエラー表示が揃ってから描画状態を切り替える。
    private func render() {
        cancelSlideshowWait(); cancelPrefetch(finishingCurrentImage: true, exceptSource: source?.url); clearLoupe()
        renderTask?.cancel()
        let id = UUID(); renderID = id
        guard let source, let page else { return }
        if page.visibleIndices.contains(source.images.count - 1) { stopSlideshow() }
        let indices = page.visibleIndices; let pixels = pixelSize
        // このページの全枠が揃うまでは、直前に完成した画面を表示し続ける。
        isDecoding = true
        renderTask = Task { [weak self, cache] in
            var result: [Int: DecodedImage] = [:]; var failures: [Int: String] = [:]
            for index in indices {
                guard !Task.isCancelled else { return }
                let entry = source.images[index]
                if let failure = entry.failure { failures[index] = failure; continue }
                do { result[index] = try await cache.image(at: entry.fileURL, maxPixelSize: pixels, retaining: source) }
                catch { failures[index] = error.localizedDescription }
            }
            withExtendedLifetime(source) {}
            guard !Task.isCancelled, let self, self.renderID == id else { return }
            self.imageFailures.merge(failures) { _, new in new }
            // 読めない画像を見開きから外し、必要なら単体表示として組み直す。
            if !failures.isEmpty {
                self.stopSlideshow()
                let revised = PageNavigator.page(at: page.anchorIndex, orientations: self.orientations, mode: self.mode, forceSingle: page.forceSingle)
                if revised != self.page { self.page = revised; self.render(); return }
            }
            self.presentedPage = PresentedPage(sourceURL: self.source?.url ?? source.url, page: page, images: result,
                failureNames: Dictionary(uniqueKeysWithValues: failures.keys.map { ($0, source.images[$0].name) }))
            self.isDecoding = false
            self.scheduleSlideshow(); self.prefetch()
        }
    }

    var canStartSlideshow: Bool {
        guard canRead, !isRendering, let source, let page,
              presentedPage?.sourceURL == source.url, presentedPage?.page == page,
              !page.visibleIndices.contains(source.images.count - 1) else { return false }
        return page.visibleIndices.allSatisfy { decoded[$0] != nil && imageFailures[$0] == nil }
    }
    func toggleSlideshow() {
        if isSlideshowPlaying { stopSlideshow() }
        else if canStartSlideshow { isSlideshowPlaying = true; scheduleSlideshow() }
    }
    @discardableResult func setSlideshowInterval(_ text: String) -> Bool {
        guard let value = SlideshowInterval.parse(text) else { return false }
        slideshowInterval = value; scheduleSlideshow(); return true
    }
    private func cancelSlideshowWait() {
        slideshowID = UUID(); slideshowTask?.cancel(); slideshowTask = nil
    }
    func stopSlideshow() { isSlideshowPlaying = false; cancelSlideshowWait() }
    func suspendSlideshow() { slideshowSuspended = true; cancelSlideshowWait() }
    func resumeSlideshow() { slideshowSuspended = false; scheduleSlideshow() }
    // ページの準備完了後から次の待機を開始する。編集・スリープ中は待機を保留する。
    private func scheduleSlideshow() {
        cancelSlideshowWait()
        guard isSlideshowPlaying, !isEditingInterval, !isPreparingPage else { return }
        guard canStartSlideshow else { if !isRendering { stopSlideshow() }; return }
        guard !slideshowSuspended else { return }
        let id = slideshowID; let delay = Duration.seconds(slideshowInterval)
        slideshowTask = Task { [weak self, wait] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self, self.slideshowID == id, self.isSlideshowPlaying else { return }
            self.move(.next) // 描画完了から改めて待機する。遅延分を取り戻す連続移動は行わない。
        }
    }

    var canUseLoupe: Bool {
        loupeEnabled && canRead && !isRendering && !suppressPrefetch &&
        presentedPage?.sourceURL == source?.url && presentedPage?.page == page
    }
    /// 表示サイズと画面倍率からルーペ用の解像度を求め、同じ要求の重複を避ける。
    func requestLoupe(index: Int, displayedSize: CGSize, backingScale: CGFloat) {
        guard canUseLoupe, let source, page?.visibleIndices.contains(index) == true,
              let metadata = source.images[index].metadata else { if loupeIndex != nil { clearLoupe() }; return }
        let pixels = CanvasGeometry.loupePixelSize(metadata: metadata, displayed: displayedSize, backingScale: backingScale)
        guard loupeIndex != index || loupePixels != pixels else { return }
        clearLoupe(); loupeIndex = index; loupePixels = pixels
        let id = loupeID; let entry = source.images[index]
        loupeTask = Task { [weak self, cache, source] in
            let image = try? await cache.image(at: entry.fileURL, maxPixelSize: pixels, use: .loupe, retaining: source)
            withExtendedLifetime(source) {}
            guard let image, !Task.isCancelled, let self, self.loupeID == id else { return }
            self.loupeImage = image
        }
    }
    func clearLoupe() {
        loupeID = UUID(); loupeTask?.cancel(); loupeTask = nil; loupeIndex = nil; loupeImage = nil; loupePixels = 0
    }
    private func cancelPrefetch(finishingCurrentImage: Bool = false, exceptSource: URL? = nil) {
        prefetchID = UUID()
        // 進行中の画像展開は完了させ、ページ移動でもその結果を共有できるようにする。
        // 世代IDの検証により、それ以降の画像へ先読みが進むことを防ぐ。
        if !finishingCurrentImage { prefetchTask?.cancel() }
        prefetchTask = nil
        Task { [cache, sourceCache] in await cache.cancelPrefetch(); await sourceCache.cancelPrefetch(except: exceptSource) }
    }
    private func prefetch() {
        guard !suppressPrefetch, canRead, !isRendering, prefetchTask == nil, let source, let page else { return }
        let id = UUID(); prefetchID = id
        let pixels = pixelSize; let mode = mode
        let before = [page.anchorIndex - 2, page.anchorIndex - 1]
        let end = page.visibleIndices.last ?? page.anchorIndex
        let after = [end + 1, end + 2]
        // 直前の移動方向を優先し、隣の見開きを読む順番で準備する。
        // ジャンプ直後も、反対側より進行方向の2枚を先にデコードする。
        let nearby = (prefetchForward ? after + before : before + after).filter { source.images.indices.contains($0) }
        prefetchTask = Task { [weak self, cache, sourceCache] in
            defer { if self?.prefetchID == id { self?.prefetchTask = nil } }
            for index in nearby {
                guard !Task.isCancelled, self?.prefetchID == id else { return }
                guard let prepared = try? await source.preparingImages(at: [index], prefetch: true), !Task.isCancelled else { return }
                guard self?.prefetchID == id else { return }
                _ = try? await cache.image(at: prepared.images[index].fileURL, maxPixelSize: pixels, use: .prefetch, retaining: prepared)
                withExtendedLifetime(prepared) {}
            }
            guard let self, self.prefetchID == id else { return }
            // 隣の本はフォルダの許可が既にある場合だけ先読みし、許可ダイアログは出さない。
            let adjacent = [self.sourceDestination(.next), self.sourceDestination(.previous)]
                .compactMap { $0 }.filter { self.fileAccess.covers($0) }
            for url in adjacent {
                guard !Task.isCancelled, self.prefetchID == id else { return }
                guard let neighbor = try? await sourceCache.load(url, prefetch: true, mode: mode) else { continue }
                guard !Task.isCancelled, self.prefetchID == id else { return }
                let first = PageNavigator.page(at: 0, orientations: neighbor.images.map(\.orientation), mode: mode)
                for index in first?.visibleIndices ?? [] {
                    guard !Task.isCancelled, self.prefetchID == id else { return }
                    _ = try? await cache.image(at: neighbor.images[index].fileURL, maxPixelSize: pixels, use: .prefetch, retaining: neighbor)
                }
                withExtendedLifetime(neighbor) {}
            }
        }
    }
    // メモリ不足時はルーペと先読みを止め、深刻度に応じてキャッシュを解放する。
    func handleMemoryPressure(critical: Bool) {
        suppressPrefetch = true; cancelPrefetch(); clearLoupe()
        let root = temporaryRoot
        Task { [cache, sourceCache] in
            try? ExtractionStorage.shared(root: root).trimFiles(prefetchedOnly: !critical)
            await cache.memoryPressure(critical: critical)
            if critical { await sourceCache.removeAll() } else { await sourceCache.removePrefetched() }
        }
    }
    func memoryPressureEnded() { suppressPrefetch = false }
    func resumeWindow() { windowIsOpen = true; if source != nil { render() } }
    func closeWindow() {
        stopSlideshow(); windowIsOpen = false; isEditingInterval = false
        cancelOpen(); clearLoupe(); renderTask?.cancel(); isDecoding = false
    }
    // 終了時は進行中の処理と表示の参照を解放し、自分が所有する展開領域を清掃する。
    func shutdown() {
        closeWindow(); source = nil; presentedPage = nil; archiveNeighbors = nil
        Task { [cache, sourceCache] in await cache.removeAll(); await sourceCache.removeAll() }
        try? ExtractionStorage.shared(root: temporaryRoot).cleanOwnedAtExit()
    }
}
