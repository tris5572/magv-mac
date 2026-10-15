import Foundation

public final class FileAccessLease: @unchecked Sendable {
    private let url: URL
    private let scoped: Bool
    public init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL
    public init(root customRoot: URL? = nil) throws {
        let root = customRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.tris.magv-native/Extraction", isDirectory: true)
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

public enum FileAccessService {
    public static func images(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true && SourceFormat.isImage($0.lastPathComponent)
            }
            .sorted { SourceFormat.naturalOrder($0.lastPathComponent, $1.lastPathComponent) }
    }
}
