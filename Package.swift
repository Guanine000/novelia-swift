// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoveliaIOSPort",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "NoveliaIOSCore", targets: ["NoveliaIOSCore"])
    ],
    dependencies: [
        // 版本固定与 Xcode 项目一致（NoveliaIOS.xcodeproj 的 Package.resolved）。
        .package(url: "https://github.com/CHANG-JUI-LIN/YueduCoreText.git", exact: "0.8.0"),
        .package(url: "https://github.com/readium/ZIPFoundation.git", exact: "3.0.1"),
        .package(url: "https://github.com/readium/swift-toolkit.git", exact: "3.11.0"),
    ],
    targets: [
        .target(
            name: "NoveliaIOSCore",
            path: "Sources/NoveliaIOSCore",
            // App 目标按 Xcode 默认设置编译这些文件，启用裸 `/regex/` 字面量。
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
        // App 的 EPUB 容器与分页书，直接编译 App 源码，
        // 让测试覆盖实际发布的代码，而不是一份副本。
        .target(
            name: "NoveliaEPUB",
            dependencies: [
                // 共享诊断与 LRU；App 把两个目录编译进同一模块，
                // 因此 EPUB 文件只在 `#if canImport(NoveliaIOSCore)` 下导入它。
                "NoveliaIOSCore",
                .product(name: "YueduCoreText", package: "YueduCoreText"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
                .product(name: "ReadiumShared", package: "swift-toolkit"),
            ],
            path: "iOSApp/Features/Reader/EPUBReader",
            exclude: [
                "DEPENDENCIES.md",
                "EPUBPagerView.swift",
                "EPUBReaderModel.swift",
                "EPUBReaderView.swift",
                "EPUBSampleBook.swift",
            ],
            sources: ["ReadiumTextPublication.swift", "EPUBChapterSource.swift", "EPUBContainer.swift", "EPUBLayoutCoordinator.swift", "EPUBPageBook.swift"]
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
