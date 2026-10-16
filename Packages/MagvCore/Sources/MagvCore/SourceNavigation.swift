import Foundation

public enum SourceNavigator {
    public static func destination(_ command: SourceCommand, current: URL, siblings: [URL]) -> URL? {
        switch command {
        case .random: return siblings.filter { !FileAccessService.sameLocation($0, current) }.randomElement()
        case .next, .previous:
            guard let index = siblings.firstIndex(where: { FileAccessService.sameLocation($0, current) }) else { return nil }
            let target = index + (command == .next ? 1 : -1)
            return siblings.indices.contains(target) ? siblings[target] : nil
        }
    }
}

public enum SourceSearch {
    public static func url(for sourceURL: URL, kind: SourceKind) -> URL? {
        let name = kind == .archive ? sourceURL.deletingPathExtension().lastPathComponent : sourceURL.lastPathComponent
        let query = name.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "t", value: "h_"), URLQueryItem(name: "q", value: query)]
        // A literal '+' must remain a plus when interpreted as a form query by the browser.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
