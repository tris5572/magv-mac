import Foundation

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    public var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct SavedWindow: Codable, Equatable, Sendable {
    public var frame: WindowFrame
    public var coordinateSpace = "appkit-screen-points"
    public init(frame: WindowFrame) { self.frame = frame }
}

public struct ReaderSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var displayMode: DisplayMode = .spread
    public var readingDirection: ReadingDirection = .rightToLeft
    public var window: SavedWindow?
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, displayMode, readingDirection, window }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        displayMode = try values.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .spread
        readingDirection = try values.decodeIfPresent(ReadingDirection.self, forKey: .readingDirection) ?? .rightToLeft
        window = try values.decodeIfPresent(SavedWindow.self, forKey: .window)
    }
}

public struct SettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> ReaderSettings? {
        guard let data = try? Data(contentsOf: url),
              var value = try? JSONDecoder().decode(ReaderSettings.self, from: data), value.schemaVersion == 1 else { return nil }
        if let window = value.window, !window.frame.isValid || window.coordinateSpace != "appkit-screen-points" { value.window = nil }
        return value
    }
    public func save(_ settings: ReaderSettings) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public enum WindowPlacement {
    public static func restore(_ saved: WindowFrame, visibleFrames: [CGRect], minimumSize: CGSize) -> CGRect? {
        let screens = visibleFrames.filter { WindowFrame($0).isValid }
        guard saved.isValid, let primary = screens.first else { return nil }
        // Bound dimensions before calculating intersections to avoid arithmetic overflow on damaged values.
        let probe = CGRect(x: saved.x, y: saved.y,
                           width: min(saved.width, screens.map(\.width).max()!),
                           height: min(saved.height, screens.map(\.height).max()!))
        let screen = screens.max {
            intersectionArea(probe, $0) < intersectionArea(probe, $1)
        }.flatMap { intersectionArea(probe, $0) > 0 ? $0 : nil } ?? primary
        let width = min(max(saved.width, minimumSize.width), screen.width)
        let height = min(max(saved.height, minimumSize.height), screen.height)
        return CGRect(x: min(max(saved.x, screen.minX), screen.maxX - width),
                      y: min(max(saved.y, screen.minY), screen.maxY - height), width: width, height: height)
    }
    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> Double {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}
