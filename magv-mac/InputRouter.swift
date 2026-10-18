import AppKit
import MagvCore

/// キー入力を閲覧コマンドへ変換する。実行や操作可否の判断は呼び出し側に任せる。
enum InputRouter {
    enum Action: Equatable { case page(PageCommand), source(SourceCommand), rename, addBang, search }

    // ページ移動を先に判定し、該当しなければソース切替や名前変更などを調べる。
    static func action(for event: NSEvent, direction: ReadingDirection) -> Action? {
        if let command = command(for: event, direction: direction) { return .page(command) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        if event.characters == "!" { return .addBang }
        guard !flags.contains(.shift) else { return nil }
        switch event.keyCode {
        case 125: return .source(.next)
        case 126: return .source(.previous)
        case 36, 76: return .rename
        default:
            switch event.characters {
            case "r": return .source(.random)
            case "f": return .search
            default: return nil
            }
        }
    }

    static func command(for event: NSEvent, direction: ReadingDirection) -> PageCommand? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.option), !flags.contains(.control) else { return nil }
        let rtl = direction == .rightToLeft; let shift = flags.contains(.shift); let command = flags.contains(.command)
        switch event.keyCode {
        // 左右キーは開き方向に従う。⌘は端へ、Shiftは見開きでも1枚ずつ移動する。
        case 123, 124:
            let next = (event.keyCode == 123) == rtl
            if command { return next ? .last : .first }
            if shift { return next ? .nextImage : .previousImage }
            return next ? .next : .previous
        // Home／Endも開き方向に合わせて先頭・末尾を入れ替える。
        case 115 where !command: return rtl ? .last : .first
        case 119 where !command: return rtl ? .first : .last
        case 49 where !command: return shift ? .previous : .next
        default: return nil
        }
    }
}
