import SwiftUI
import MagvCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: ReaderSession
    let openPanel: () -> Void
    @State private var hoverControls = false

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
                        HStack(spacing: 16) {
                            Picker("表示", selection: $session.mode) {
                                Text("単体").tag(DisplayMode.single)
                                Text("見開き").tag(DisplayMode.spread)
                            }.pickerStyle(.segmented).frame(width: 130)
                            Picker("開き方向", selection: $session.direction) {
                                Text("右開き").tag(ReadingDirection.rightToLeft)
                                Text("左開き").tag(ReadingDirection.leftToRight)
                            }.pickerStyle(.segmented).frame(width: 150)
                            Spacer(minLength: 0)
                            Button(action: openPanel) { Image(systemName: "folder") }.help("ファイルを開く")
                        }.padding(12).background(.regularMaterial)
                            .opacity(hoverControls ? 1 : 0).allowsHitTesting(hoverControls).accessibilityHidden(!hoverControls)
                        Color.clear.frame(height: 16)
                    }.frame(height: 66).onHover { hoverControls = $0 }
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
        .alert("開けませんでした", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
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
