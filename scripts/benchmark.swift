import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import MagvCore

/// 合成データの生成と、選択展開・全件展開の比較計測を行う補助ツール。
@main struct ReaderBenchmark {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--generate", "--generate-large"].contains(arguments.first ?? ""), let path = arguments.last {
            try generate(URL(fileURLWithPath: path, isDirectory: true), large: arguments.first == "--generate-large"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("magv-benchmark-" + UUID().uuidString)
        let storage = try ExtractionStorage(root: root)
        defer { storage.cleanOwnedAtExit(); try? FileManager.default.removeItem(at: root) }
        for path in arguments where path != "--compare" {
            let url = URL(fileURLWithPath: path)
            if arguments.contains("--compare"), SourceFormat.archiveExtensions.contains(url.pathExtension.lowercased()) {
                try await measureEager(url, storage: storage)
            }
            try await measure(url, storage: storage)
        }
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    // 初期表示、先読み後の移動、同じ本の再訪を分けて測定する。UI描画時間は含まない。
    static func measure(_ url: URL, storage: ExtractionStorage) async throws {
        let sources = SourceCache(storage: storage)
        let images = ImageCache()
        let clock = ContinuousClock()
        let start = clock.now
        let source = try await sources.load(url)
        let page = PageNavigator.page(at: 0, orientations: source.images.map(\.orientation), mode: .spread)!
        for index in page.visibleIndices { _ = try await images.image(at: source.images[index].fileURL, maxPixelSize: 2048, retaining: source) }
        let initial = milliseconds(start.duration(to: clock.now))
        let initialBytes = storage.byteCount
        let nextAnchor = (page.visibleIndices.last ?? 0) + 1
        let warmed = try await source.preparingImages(at: [nextAnchor, nextAnchor + 1], prefetch: true)
        let next = PageNavigator.move(.next, from: page, orientations: warmed.images.map(\.orientation), mode: .spread)!
        for index in next.visibleIndices { _ = try await images.image(at: warmed.images[index].fileURL, maxPixelSize: 2048, use: .prefetch, retaining: warmed) }
        let turnStart = clock.now
        let ready = try await warmed.preparingImages(at: next.visibleIndices)
        for index in next.visibleIndices { _ = try await images.image(at: ready.images[index].fileURL, maxPixelSize: 2048, retaining: ready) }
        withExtendedLifetime((warmed, ready)) {}
        let turn = milliseconds(turnStart.duration(to: clock.now))
        let revisitStart = clock.now
        _ = try await sources.load(url)
        let revisit = milliseconds(revisitStart.duration(to: clock.now))
        let counts = await images.byteCounts
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("\(url.lastPathComponent): \(source.images.count) images (on-demand)")
        print(String(format: "  extraction at first display: %.2f MiB", Double(initialBytes) / 1048576))
        print(String(format: "  load + first spread decode: %.2f ms; cached next spread: %.3f ms; source revisit: %.3f ms", initial, turn, revisit))
        print(String(format: "  image cache: %.2f MiB; extraction: %.2f MiB; process peak RSS: %.2f MiB", Double(counts.display) / 1048576, Double(storage.byteCount) / 1048576, Double(usage.ru_maxrss) / 1048576))
        await sources.removeAll(); await images.removeAll()
    }
    // 全画像を先に展開・寸法取得する経路を、選択展開との比較基準として測る。
    static func measureEager(_ url: URL, storage: ExtractionStorage) async throws {
        let directory = try TemporaryDirectory(storage: storage)
        let clock = ContinuousClock(); let start = clock.now
        let files = try ArchiveReader.extract(url, into: directory.url, reserveBytes: directory.reserve)
        let metadata = try files.map { try ImageDecoder.metadata(at: $0.fileURL) }
        let page = PageNavigator.page(at: 0, orientations: metadata.map(\.orientation), mode: .spread)!
        let cache = ImageCache()
        for index in page.visibleIndices { _ = try await cache.image(at: files[index].fileURL, maxPixelSize: 2048) }
        let elapsed = milliseconds(start.duration(to: clock.now))
        print(String(format: "\(url.lastPathComponent): eager reference, first spread %.2f ms; extraction %.2f MiB", elapsed, Double(storage.byteCount) / 1048576))
        await cache.removeAll(); withExtendedLifetime(directory) {}
    }
    // 固定シードで同じ模様を生成し、入力データの差による計測のばらつきを抑える。
    static func generate(_ directory: URL, large: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = large ? 2000 : 1440, height = large ? 3000 : 2160
        var pixels = [UInt8](repeating: 255, count: width * height)
        var random: UInt64 = 12345
        for y in 0..<height { for x in 0..<width {
            random = random &* 6364136223846793005 &+ 1
            let border = x % 480 < 8 || y % 720 < 8
            pixels[y * width + x] = border || random >> 56 > 247 ? 0 : ((x + y) % 17 == 0 ? 180 : 255)
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let suffix = large ? "jpg" : "png"
        let first = directory.appendingPathComponent("1." + suffix)
        func writeImage(quality: Double) throws {
            let destination = CGImageDestinationCreateWithURL(first as CFURL, (large ? UTType.jpeg : .png).identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, large ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary : nil)
            guard CGImageDestinationFinalize(destination) else { throw ReaderError.invalidImage("benchmark") }
        }
        if large {
            // 合成JPEGの品質を調整し、300ページ全体を基準の500MiB未満に収める。
            var lower = 0.05, upper = 0.9
            var selected: Data?
            for _ in 0..<7 {
                let quality = (lower + upper) / 2
                try writeImage(quality: quality)
                let data = try Data(contentsOf: first)
                if data.count <= 480 * 1024 * 1024 / 300 { selected = data; lower = quality }
                else { upper = quality }
            }
            guard let selected else { throw ReaderError.invalidImage("benchmark JPEG size") }
            try selected.write(to: first)
            print(String(format: "Synthetic input: 2000x3000 JPEG x 300, %.2f MiB before ZIP", Double(selected.count * 300) / 1048576))
        } else { try writeImage(quality: 0.8) }
        for index in 2...(large ? 300 : 100) { try FileManager.default.copyItem(at: first, to: directory.appendingPathComponent("\(index)." + suffix)) }
    }
}
