// swift-tools-version: 5.9
import PackageDescription

// libmobi v0.12 的 C 源码，供 AZW3／MOBI 导入转换使用。来源、取舍与编译选项见 README.md。
let package = Package(
    name: "CLibMobi",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CLibMobi", targets: ["CLibMobi"])
    ],
    targets: [
        .target(
            name: "CLibMobi",
            path: "Sources/CLibMobi",
            cSettings: [
                // 只启用 OPF/NCX 生成（内置 xmlwriter）；不定义 USE_ENCRYPTION，不编译任何 DRM 处理代码。
                .define("USE_XMLWRITER"),
                .define("HAVE_STRDUP"),
                .define("HAVE_UNISTD_H"),
                .define("PACKAGE_VERSION", to: "\"0.12\""),
                .unsafeFlags(["-w"]),
            ],
            // 未定义 USE_MINIZ 时 libmobi 使用系统 zlib 解压字体等资源。
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
