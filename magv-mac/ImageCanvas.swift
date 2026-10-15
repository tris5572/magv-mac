import AppKit
import SwiftUI
import MagvCore

struct ImageCanvas: NSViewRepresentable {
    let session: ReaderSession
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        _ = session.page; _ = session.decoded; _ = session.direction; _ = session.imageFailures
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("漫画のページ")
        view.setAccessibilityValue(session.pageLabel)
        view.needsDisplay = true
    }
}

@MainActor final class CanvasView: NSView {
    let session: ReaderSession
    private var wheelAmount: CGFloat = 0
    private var wheelTurned = false
    private var lastWheelTime: TimeInterval = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(session: ReaderSession) { self.session = session; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        session.updatePixelSize(Int(max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.07, alpha: 1).setFill(); bounds.fill()
        guard let page = session.page, let context = NSGraphicsContext.current?.cgContext else { return }
        var indices = page.visibleIndices
        if session.direction == .rightToLeft { indices.reverse() }
        let width = bounds.width / CGFloat(indices.count)
        for (position, index) in indices.enumerated() {
            let slot = NSRect(x: CGFloat(position) * width, y: 0, width: width, height: bounds.height)
            guard let decoded = session.decoded[index] else {
                let failed = session.imageFailures[index] != nil || session.source?.images[index].failure != nil
                let message = failed ? "画像を読み込めません\n\(session.source?.images[index].name ?? "")" : "読み込み中…"
                let style = NSMutableParagraphStyle(); style.alignment = .center
                (message as NSString).draw(in: NSRect(x: slot.minX + 16, y: slot.midY - 30, width: slot.width - 32, height: 100),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
                continue
            }
            let image = decoded.image
            let scale = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let x = indices.count == 1 ? slot.midX - size.width / 2 : (position == 0 ? slot.maxX - size.width : slot.minX)
            let rect = NSRect(x: x, y: slot.midY - size.height / 2, width: size.width, height: size.height)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: NSRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseMoved(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(false) }
    override func mouseExited(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(false) }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), session.canRead else { return }
        let now = event.timestamp
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) || now - lastWheelTime > 0.35 { wheelAmount = 0; wheelTurned = false }
            lastWheelTime = now
            guard !wheelTurned else { return }
            wheelAmount += event.scrollingDeltaY
            if abs(wheelAmount) >= 24 { session.move(wheelAmount > 0 ? .next : .previous); wheelTurned = true }
        } else if now - lastWheelTime > 0.12 {
            lastWheelTime = now; session.move(event.scrollingDeltaY > 0 ? .next : .previous)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        NSCursor.setHiddenUntilMouseMoves(false)
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, command) in [("次ページ", PageCommand.next), ("前ページ", .previous), ("最初へ", .first), ("最後へ", .last)] {
            let item = NSMenuItem(title: title, action: #selector(contextMove(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command; item.isEnabled = session.canMove(command)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "フルスクリーン", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        fullScreen.target = window; menu.addItem(fullScreen)
        return menu
    }

    @objc private func contextMove(_ item: NSMenuItem) {
        if let command = item.representedObject as? PageCommand { session.move(command) }
    }
}
