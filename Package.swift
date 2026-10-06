// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoveliaIOSPort",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NoveliaIOSCore", targets: ["NoveliaIOSCore"])
    ],
    targets: [
        .target(name: "NoveliaIOSCore", path: "Sources/NoveliaIOSCore")
    ]
)
