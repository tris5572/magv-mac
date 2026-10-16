import Foundation

public enum SourceLoader {
    public static func load(_ selectedURL: URL, limits: ReaderLimits = ReaderLimits(),
                             temporaryRoot: URL? = nil,
                             storage: ExtractionStorage? = nil,
                             progress: @Sendable (String) -> Void = { _ in }) throws -> LoadedSource {
        let url = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        let access = FileAccessLease(url: selectedURL)
        do {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let sourceURL: URL
            let kind: SourceKind
            let temporary: TemporaryDirectory?
            let files: [(String, URL)]
            var initialIndex: Int?
            var partialDirectory = false
            var revision: FileRevision?
            if values.isDirectory == true {
                sourceURL = URL(fileURLWithPath: url.path, isDirectory: true)
                kind = .directory
                temporary = nil
                files = try FileAccessService.images(in: url).map { ($0.lastPathComponent, $0) }
            } else if SourceFormat.archiveExtensions.contains(url.pathExtension.lowercased()) {
                sourceURL = url
                kind = .archive
                revision = try FileRevision.read(url)
                let directory = try TemporaryDirectory(storage: storage ?? ExtractionStorage.shared(root: temporaryRoot))
                temporary = directory
                files = try ArchiveReader.extract(url, into: directory.url, limits: limits, reserveBytes: directory.reserve, progress: { count in
                    progress("画像を展開中… \(count)枚")
                }).map { ($0.path, $0.fileURL) }
            } else if SourceFormat.isImage(url.lastPathComponent) {
                sourceURL = url.deletingLastPathComponent()
                kind = .directory
                temporary = nil
                // A selected image can remain readable even if its parent isn't authorized.
                let directoryImages = try? FileAccessService.images(in: sourceURL)
                partialDirectory = directoryImages == nil
                let urls = directoryImages?.contains(where: { $0.resolvingSymlinksInPath().path == url.path }) == true ? directoryImages! : [url]
                files = urls.map { ($0.lastPathComponent, $0) }
                initialIndex = urls.firstIndex { $0.resolvingSymlinksInPath().path == url.path }
            } else { throw ReaderError.unsupported }
            guard !files.isEmpty else { throw ReaderError.noImages }
            guard files.count <= limits.entryCount else { throw ReaderError.limit("画像数") }
            var images: [ImageEntry] = []
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                if index % 16 == 0 { progress("画像を確認中… \(index + 1) / \(files.count)") }
                var metadata: ImageMetadata?
                var failure: String?
                do { metadata = try ImageDecoder.metadata(at: file.1, limits: limits) }
                catch let error as ReaderError {
                    if case .limit = error { throw error }
                    failure = error.localizedDescription
                } catch { failure = error.localizedDescription }
                images.append(ImageEntry(id: file.0, name: file.0, fileURL: file.1, metadata: metadata, failure: failure))
            }
            if let revision, try FileRevision.read(sourceURL) != revision { throw ReaderError.sourceChanged }
            let siblings = try? FileAccessService.siblings(of: sourceURL, kind: kind)
            return LoadedSource(url: sourceURL, kind: kind, images: images, initialIndex: initialIndex,
                access: access, temporaryDirectory: temporary, siblings: siblings ?? [sourceURL],
                needsParentAccess: siblings == nil, isPartialDirectory: partialDirectory, revision: revision)
        } catch let error as CocoaError {
            switch error.code {
            case .fileReadNoPermission: throw ReaderError.permission
            case .fileReadNoSuchFile: throw ReaderError.missing
            default: throw error
            }
        }
    }
}
