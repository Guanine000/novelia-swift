// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoveliaECH",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "NoveliaECH", targets: ["NoveliaECH"]),
    ],
    targets: [
        .binaryTarget(
            name: "NoveliaECH",
            path: "NoveliaECH.xcframework"
        ),
    ]
)
