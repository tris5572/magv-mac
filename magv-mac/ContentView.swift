import SwiftUI
import MagvCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: ReaderSession
    let openPanel: () -> Void
    @State private var hoverControls = false
    @State private var showPageLoading = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color(white: 0.07)
                if session.source != nil {
                    ImageCanvas(session: session)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "book.closed").font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
                        Text("漫画を開く").font(.title2)
                        Text("ZIP・RAR・画像・画像フォルダをドロップ").font(.callout).foregroundStyle(.secondary)
                        Button("開く…", action: openPanel)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if session.source != nil {
                    VStack(spacing: 0) {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Picker("表示", selection: $session.mode) {
                                    Text("単体").tag(DisplayMode.single)
                                    Text("見開き").tag(DisplayMode.spread)
                                }.pickerStyle(.segmented).frame(width: 100)
                                Picker("開き方向", selection: $session.direction) {
                                    Text("右開き").tag(ReadingDirection.rightToLeft)
                                    Text("左開き").tag(ReadingDirection.leftToRight)
                                }.pickerStyle(.segmented).frame(width: 116)
                                Spacer(minLength: 0)
                                Toggle(isOn: $session.loupeEnabled) { Image(systemName: "plus.magnifyingglass") }
                                    .toggleStyle(.button).help("ルーペ").accessibilityLabel("ルーペ")
                                Button(action: openPanel) { Image(systemName: "folder") }.help("ファイルを開く")
                            }
                            HStack(spacing: 12) {
                                Button(action: session.toggleSlideshow) {
                                    Label(session.isSlideshowPlaying ? "停止" : "自動再生", systemImage: session.isSlideshowPlaying ? "stop.fill" : "play.fill")
                                }.disabled(!session.isSlideshowPlaying && !session.canStartSlideshow)
                                Menu("\(session.slideshowInterval.formatted())秒") {
                                    ForEach([0.5, 1, 3, 5, 10, 30], id: \.self) { value in
                                        Button("\(value.formatted())秒") { session.setSlideshowInterval(String(value)) }
                                    }
                                    Divider()
                                    Button("間隔を指定…") { session.isEditingInterval = true }
                                }.accessibilityLabel("再生間隔")
                                Spacer(minLength: 0)
                            }
                        }.padding(10).background(.regularMaterial)
                            .opacity(hoverControls ? 1 : 0).allowsHitTesting(hoverControls).accessibilityHidden(!hoverControls)
                        Color.clear.frame(height: 16)
                    }.frame(height: 102).onHover { hoverControls = $0 }
                }
                if session.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(session.loadingMessage).font(.callout).lineLimit(2)
                        Button("キャンセル") { session.cancelOpen() }.keyboardShortcut(.cancelAction)
                    }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.clipped()
                .overlay(alignment: .bottomTrailing) {
                    if showPageLoading && !session.isLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("ページを読み込み中…").font(.callout)
                            Button("キャンセル") { session.cancelPageLoad() }
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(12)
                    }
                }
                .task(id: session.isPreparingPage) {
                    showPageLoading = false
                    if session.isPreparingPage {
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        if !Task.isCancelled { showPageLoading = true }
                    }
                }
            PageIndicator(session: session)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 320, minHeight: 240)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in session.open(url) }
            }
            return true
        }
        .sheet(isPresented: $session.isEditingInterval) {
            SlideshowIntervalEditor(session: session)
        }
        .alert(session.errorTitle, isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
}

private struct PageIndicator: View {
    @Bindable var session: ReaderSession
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.14)
                HStack(spacing: 0) {
                    if session.direction == .rightToLeft { Spacer(minLength: 0) }
                    Color.accentColor.opacity(0.4)
                        .frame(width: geometry.size.width * PageNavigator.progress(page: session.page, count: session.source?.images.count ?? 0))
                    if session.direction == .leftToRight { Spacer(minLength: 0) }
                }
                Text(session.pageLabel).font(.system(size: 12, weight: .medium, design: .monospaced))
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard geometry.size.width > 0,
                          let index = PageNavigator.index(at: value.location.x / geometry.size.width,
                            count: session.source?.images.count ?? 0, direction: session.direction) else { return }
                    session.jump(to: index)
                })
                .accessibilityElement(children: .ignore).accessibilityLabel("ページ").accessibilityValue(session.pageLabel)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: session.move(.nextImage)
                    case .decrement: session.move(.previousImage)
                    @unknown default: break
                    }
                }
        }.frame(height: 32)
    }
}

private struct SlideshowIntervalEditor: View {
    @Bindable var session: ReaderSession
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("再生間隔").font(.headline)
            Text("0.5〜100,000秒を0.5秒刻みで指定してください。")
            HStack {
                TextField("秒", text: $text).focused($focused).frame(width: 150).onSubmit(apply)
                Stepper("秒", onIncrement: { step(0.5) }, onDecrement: { step(-0.5) }).labelsHidden()
            }
            if invalid { Text("有効な秒数を0.5秒刻みで入力してください。").foregroundStyle(.red).accessibilityLabel("再生間隔の入力エラー") }
            HStack {
                Spacer()
                Button("キャンセル") { session.isEditingInterval = false }.keyboardShortcut(.cancelAction)
                Button("適用", action: apply).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380)
            .onAppear { text = String(session.slideshowInterval); focused = true }
    }
    private func step(_ amount: Double) {
        let value = SlideshowInterval.parse(text) ?? session.slideshowInterval
        text = String(min(100_000, max(0.5, value + amount))); invalid = false
    }
    private func apply() {
        if session.setSlideshowInterval(text) { session.isEditingInterval = false }
        else { invalid = true }
    }
}
