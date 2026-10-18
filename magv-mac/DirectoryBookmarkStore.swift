import Foundation

/// フォルダの許可情報を、表示設定や起動中だけの閲覧履歴とは別に保存する。
struct DirectoryBookmarkStore {
    let url: URL
    private struct Document: Codable {
        var schemaVersion = 1
        var folders: [Data]
    }

    // 未作成・破損・未対応バージョンの保存データは、許可情報なしとして扱う。
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

    // 一時ファイルからの置換で保存し、書き込み途中のJSONが残ることを避ける。
    func save(_ folders: [Data]) throws {
        let data = try JSONEncoder().encode(Document(folders: folders))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// ブックマークの生成・復元を差し替え可能にし、OSの権限機構に依存せずテストできる。
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
