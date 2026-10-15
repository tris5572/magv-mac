import Foundation

public enum PageNavigator {
    public static func page(at index: Int, orientations: [ImageOrientation], mode: DisplayMode,
                            forceSingle: Bool = false) -> DisplayPage? {
        guard !orientations.isEmpty else { return nil }
        let index = min(max(index, 0), orientations.count - 1)
        let spread = mode == .spread && !forceSingle && index + 1 < orientations.count
            && orientations[index] == .portrait && orientations[index + 1] == .portrait
        return DisplayPage(anchorIndex: index, visibleIndices: spread ? [index, index + 1] : [index],
                           forceSingle: forceSingle)
    }

    public static func move(_ command: PageCommand, from current: DisplayPage?,
                            orientations: [ImageOrientation], mode: DisplayMode) -> DisplayPage? {
        guard let current, !orientations.isEmpty else { return nil }
        let index = current.anchorIndex
        guard orientations.indices.contains(index) else { return nil }
        var target = index
        var forceSingle = false
        switch command {
        case .next, .nextImage:
            guard (current.visibleIndices.last ?? index) < orientations.count - 1 else { return current }
            target += command == .next ? current.visibleIndices.count : 1
        case .previous:
            guard index > 0 else { return current }
            if mode == .spread {
                let pair = index >= 2 && orientations[index - 2] == .portrait && orientations[index - 1] == .portrait
                target -= pair ? 2 : 1
                forceSingle = !pair
            } else { target -= 1 }
        case .previousImage:
            guard index > 0 else { return current }
            target -= 1
        case .first: target = 0
        case .last:
            target = orientations.count - 1
            if mode == .spread && target > 0 && orientations[target] == .portrait && orientations[target - 1] == .portrait {
                target -= 1
            }
        }
        return page(at: target, orientations: orientations, mode: mode, forceSingle: forceSingle)
    }

    public static func index(at fraction: Double, count: Int, direction: ReadingDirection) -> Int? {
        guard count > 0, fraction.isFinite else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let position = direction == .rightToLeft ? 1 - clamped : clamped
        return min(Int(floor(position * Double(count))), count - 1)
    }

    public static func progress(page: DisplayPage?, count: Int) -> Double {
        guard let page, count > 0 else { return 0 }
        return count == 1 ? 1 : Double(page.anchorIndex) / Double(count - 1)
    }
}
