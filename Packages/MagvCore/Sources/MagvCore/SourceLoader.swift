import Foundation

/// 選択URLをアーカイブ・画像・フォルダに分類し、共通のLoadedSourceへ変換する。
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
            if values.isDirectory == true {
                sourceURL = URL(fileURLWithPath: url.path, isDirectory: true)
                kind = .directory
                temporary = nil
                files = try FileAccessService.images(in: url).map { ($0.lastPathComponent, $0) }
            } else if SourceFormat.archiveExtensions.contains(url.pathExtension.lowercased()) {
                sourceURL = url
                kind = .archive
                progress("画像の一覧を確認中…")
                // アーカイブは一覧だけを先に読み、画像の実体は表示時にArchiveImageStoreで展開する。
                let index = try ArchiveReader.index(url, limits: limits)
                guard !index.members.isEmpty else { throw ReaderError.noImages }
                let directory = try TemporaryDirectory(storage: storage ?? ExtractionStorage.shared(root: temporaryRoot))
                let images = ArchiveImageStore(url: url, index: index, directory: directory, access: access, limits: limits)
                let siblings = try? FileAccessService.siblings(of: url, kind: .archive)
                return LoadedSource(url: url, kind: .archive, images: images.initialEntries, initialIndex: nil, access: access, temporaryDirectory: directory, siblings: siblings ?? [url],
                needsParentAccess: siblings == nil, isPartialDirectory: false, revision: index.revision, archive: images)
            } else if SourceFormat.isImage(url.lastPathComponent) {
                sourceURL = url.deletingLastPathComponent()
                kind = .directory
                temporary = nil
                // 親フォルダが未許可でも、選択した画像そのものは読み込めるようにする。
                let directoryImages = try? FileAccessService.images(in: sourceURL)
                partialDirectory = directoryImages == nil
                let urls = directoryImages?.contains(where: { $0.resolvingSymlinksInPath().path == url.path }) == true ? directoryImages! : [url]
                files = urls.map { ($0.lastPathComponent, $0) }
                initialIndex = urls.firstIndex { $0.resolvingSymlinksInPath().path == url.path }
            } else { throw ReaderError.unsupported }
            guard !files.isEmpty else { throw ReaderError.noImages }
            guard files.count <= limits.entryCount else { throw ReaderError.limit("画像数") }
            var images: [ImageEntry] = []
            // 直接参照できる画像は寸法を列挙時に確認する。壊れた1枚は失敗情報として残す。
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
            let siblings = try? FileAccessService.siblings(of: sourceURL, kind: kind)
            return LoadedSource(url: sourceURL, kind: kind, images: images, initialIndex: initialIndex,
                access: access, temporaryDirectory: temporary, siblings: siblings ?? [sourceURL],
                needsParentAccess: siblings == nil, isPartialDirectory: partialDirectory, revision: nil)
        } catch let error as CocoaError {
            switch error.code {
            case .fileReadNoPermission: throw ReaderError.permission
            case .fileReadNoSuchFile: throw ReaderError.missing
            default: throw error
            }
        }
    }
}
