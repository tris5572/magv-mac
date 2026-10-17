import AppKit
import SwiftUI
import MagvCore

struct ImageCanvas: NSViewRepresentable {
    let session: ReaderSession
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        _ = session.page; _ = session.decoded; _ = session.direction; _ = session.imageFailures
        _ = session.canUseLoupe; _ = session.loupeImage; _ = session.loupeIndex; _ = session.canRead
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("漫画のページ")
        view.setAccessibilityValue(session.pageLabel)
        view.needsDisplay = true
        Task { @MainActor [weak view] in view?.refreshLoupe() }
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
        refreshLoupe()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; refreshLoupe() }

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
            let rect = CanvasGeometry.imageRect(size: CGSize(width: image.width, height: image.height), slot: slot, position: position, count: indices.count)
            drawImage(image, in: rect, context: context)
        }
        if let (index, rect, pointer) = hoveredImage(), session.canUseLoupe,
           let preview = session.decoded[index] {
            let lens = CGRect(x: pointer.x - 300, y: pointer.y - 300, width: 600, height: 600)
            guard let enlarged = CanvasGeometry.magnifiedRect(image: rect, pointer: pointer, lens: lens) else { return }
            let image = session.loupeIndex == index ? (session.loupeImage ?? preview).image : preview.image
            context.saveGState()
            context.clip(to: bounds); context.clip(to: lens)
            NSColor(white: 0.07, alpha: 1).setFill(); lens.fill()
            drawImage(image, in: enlarged, context: context)
            NSColor.white.withAlphaComponent(0.65).setStroke()
            let border = NSBezierPath(rect: lens.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
            context.restoreGState()
        }
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    private func hoveredImage() -> (Int, CGRect, CGPoint)? {
        guard let window, window.isKeyWindow, let page = session.page else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point), point.y >= 102 else { return nil }
        let indices = session.direction == .rightToLeft ? Array(page.visibleIndices.reversed()) : page.visibleIndices
        let width = bounds.width / CGFloat(indices.count)
        for (position, index) in indices.enumerated() {
            guard let decoded = session.decoded[index] else { continue }
            let rect = CanvasGeometry.imageRect(size: CGSize(width: decoded.image.width, height: decoded.image.height),
                slot: CGRect(x: CGFloat(position) * width, y: 0, width: width, height: bounds.height), position: position, count: indices.count)
            if rect.contains(point) { return (index, rect, point) }
        }
        return nil
    }
    func refreshLoupe() {
        if session.canUseLoupe, let (index, rect, _) = hoveredImage() {
            session.requestLoupe(index: index, displayedSize: rect.size, backingScale: window?.backingScaleFactor ?? 1)
        } else if session.loupeIndex != nil { session.clearLoupe() }
        needsDisplay = true
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, session.canRead { session.loupeEnabled.toggle(); refreshLoupe() }
        else { super.otherMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseMoved(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(false); refreshLoupe() }
    override func mouseEntered(with event: NSEvent) { refreshLoupe() }
    override func mouseExited(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(false); session.clearLoupe(); needsDisplay = true }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), session.canRead else { return }
        // AppKit applies the system scroll direction; a negative delta scrolls down.
        let now = event.timestamp
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) || now - lastWheelTime > 0.35 { wheelAmount = 0; wheelTurned = false }
            lastWheelTime = now
            guard !wheelTurned else { return }
            wheelAmount += event.scrollingDeltaY
            if abs(wheelAmount) >= 24 { session.move(wheelAmount < 0 ? .next : .previous); wheelTurned = true }
        } else if now - lastWheelTime > 0.12 {
            lastWheelTime = now; session.move(event.scrollingDeltaY < 0 ? .next : .previous)
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
