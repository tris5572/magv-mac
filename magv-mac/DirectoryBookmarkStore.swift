import Foundation

/// Kept separate from display preferences and in-memory reading history.
struct DirectoryBookmarkStore {
    let url: URL
    private struct Document: Codable {
        var schemaVersion = 1
        var folders: [Data]
    }

    func load() -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            return document.schemaVersion == 1 ? document.folders : []
        } catch {
            NSLog("magv: フォルダの許可情報を読み込めません: %@", error.localizedDescription)
            return []
        }
    }

    func save(_ folders: [Data]) throws {
        let data = try JSONEncoder().encode(Document(folders: folders))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor struct DirectoryBookmarkCodec {
    var create: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, stale: Bool)

    static let securityScoped = DirectoryBookmarkCodec(
        create: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        })
}
