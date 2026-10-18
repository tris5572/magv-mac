// swift-tools-version: 6.2
import PackageDescription

// コア処理をUIから独立したライブラリとして公開する。
let package = Package(
    name: "MagvCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MagvCore", targets: ["MagvCore"])],
    targets: [
        // libarchiveは同梱バイナリを使い、初回ビルドでも外部パッケージの取得を不要にする。
        .binaryTarget(name: "CArchive", path: "Vendor/CArchive.xcframework"),
        .target(name: "MagvCore", dependencies: ["CArchive"],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv")]),
        // 実アーカイブと画像をテスト資源としてコピーし、形式ごとの読み込みを検証する。
        .testTarget(name: "MagvCoreTests", dependencies: ["MagvCore"], resources: [.copy("Fixtures")])
    ]
)
