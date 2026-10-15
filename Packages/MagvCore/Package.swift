// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MagvCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MagvCore", targets: ["MagvCore"])],
    targets: [
        .binaryTarget(name: "CArchive", path: "Vendor/CArchive.xcframework"),
        .target(name: "MagvCore", dependencies: ["CArchive"],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")]),
        .testTarget(name: "MagvCoreTests", dependencies: ["MagvCore"], resources: [.copy("Fixtures")])
    ]
)
