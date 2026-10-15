import AppKit
import MagvCore

enum InputRouter {
    static func command(for event: NSEvent, direction: ReadingDirection) -> PageCommand? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.option), !flags.contains(.control) else { return nil }
        let rtl = direction == .rightToLeft; let shift = flags.contains(.shift); let command = flags.contains(.command)
        switch event.keyCode {
        case 123, 124:
            let next = (event.keyCode == 123) == rtl
            if command { return next ? .last : .first }
            if shift { return next ? .nextImage : .previousImage }
            return next ? .next : .previous
        case 115 where !command: return rtl ? .last : .first
        case 119 where !command: return rtl ? .first : .last
        case 49 where !command: return shift ? .previous : .next
        default: return nil
        }
    }
}
