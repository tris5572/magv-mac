import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import MagvCore

@main struct ReaderBenchmark {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--generate", let path = arguments.last {
            try generate(URL(fileURLWithPath: path, isDirectory: true)); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("magv-benchmark-" + UUID().uuidString)
        let storage = try ExtractionStorage(root: root)
        defer { storage.cleanOwnedAtExit(); try? FileManager.default.removeItem(at: root) }
        for path in arguments { try await measure(URL(fileURLWithPath: path), storage: storage) }
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func measure(_ url: URL, storage: ExtractionStorage) async throws {
        let sources = SourceCache(storage: storage)
        let images = ImageCache()
        let clock = ContinuousClock()
        let start = clock.now
        let source = try await sources.load(url)
        let page = PageNavigator.page(at: 0, orientations: source.images.map(\.orientation), mode: .spread)!
        for index in page.visibleIndices { _ = try await images.image(at: source.images[index].fileURL, maxPixelSize: 2048) }
        let initial = milliseconds(start.duration(to: clock.now))
        let next = PageNavigator.move(.next, from: page, orientations: source.images.map(\.orientation), mode: .spread)!
        for index in next.visibleIndices { _ = try await images.image(at: source.images[index].fileURL, maxPixelSize: 2048, use: .prefetch) }
        let turnStart = clock.now
        for index in next.visibleIndices { _ = try await images.image(at: source.images[index].fileURL, maxPixelSize: 2048) }
        let turn = milliseconds(turnStart.duration(to: clock.now))
        let revisitStart = clock.now
        _ = try await sources.load(url)
        let revisit = milliseconds(revisitStart.duration(to: clock.now))
        let counts = await images.byteCounts
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("\(url.lastPathComponent): \(source.images.count) images")
        print(String(format: "  load + first spread decode: %.2f ms; cached next spread: %.3f ms; source revisit: %.3f ms", initial, turn, revisit))
        print(String(format: "  image cache: %.2f MiB; extraction: %.2f MiB; process peak RSS: %.2f MiB", Double(counts.display) / 1048576, Double(storage.byteCount) / 1048576, Double(usage.ru_maxrss) / 1048576))
        await sources.removeAll(); await images.removeAll()
    }
    static func generate(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 1440, height = 2160
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
        let first = directory.appendingPathComponent("1.png")
        let destination = CGImageDestinationCreateWithURL(first as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ReaderError.invalidImage("benchmark") }
        for index in 2...100 { try FileManager.default.copyItem(at: first, to: directory.appendingPathComponent("\(index).png")) }
    }
}
