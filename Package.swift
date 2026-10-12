// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoveliaIOSPort",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NoveliaIOSCore", targets: ["NoveliaIOSCore"])
    ],
    dependencies: [
        // Same pins as the Xcode project (NoveliaIOS.xcodeproj Package.resolved).
        .package(url: "https://github.com/CHANG-JUI-LIN/YueduCoreText.git", exact: "0.8.0"),
        .package(url: "https://github.com/readium/ZIPFoundation.git", exact: "3.0.1"),
    ],
    targets: [
        .target(
            name: "NoveliaIOSCore",
            path: "Sources/NoveliaIOSCore",
            // The app target compiles these files with Xcode's default of bare `/regex/` literals.
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        // The app's EPUB container and page book, compiled from their app sources so
        // tests exercise the shipped code rather than a copy.
        .target(
            name: "NoveliaEPUB",
            dependencies: [
                .product(name: "YueduCoreText", package: "YueduCoreText"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "iOSApp/EPUBReader",
            exclude: [
                "DEPENDENCIES.md",
                "EPUBPagerView.swift",
                "EPUBReaderModel.swift",
                "EPUBReaderView.swift",
                "EPUBSampleBook.swift",
            ],
            sources: ["EPUBContainer.swift", "EPUBPageBook.swift"]
        ),
        .testTarget(name: "NoveliaIOSCoreTests", dependencies: ["NoveliaIOSCore"], path: "Tests/NoveliaIOSCoreTests"),
        .testTarget(
            name: "NoveliaEPUBTests",
            dependencies: [
                "NoveliaEPUB",
                .product(name: "YueduCoreText", package: "YueduCoreText"),
            ],
            path: "Tests/NoveliaEPUBTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
