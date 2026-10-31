// swift-tools-version: 5.9
import Foundation
import PackageDescription

// 本地包源码位于开发者主目录下，目标文件与调试映射会记录其绝对路径并进入 Release 二进制，
// 发布隐私检查会拒绝。与 App 的 Swift 源码（`-file-prefix-map $(SRCROOT)=/Novelia`）一样改写为固定前缀。
// 编译时的工作目录（工程根目录）也可能写入调试信息，因此再按主目录前缀兜底改写；clang 优先使用后列出的映射。
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let homePrefix = packageRoot.split(separator: "/", omittingEmptySubsequences: true).prefix(2)
    .reduce("") { "\($0)/\($1)" }
let prefixMaps = (homePrefix.hasPrefix("/Users/") || homePrefix.hasPrefix("/home/") ? ["-ffile-prefix-map=\(homePrefix)=/~"] : [])
    + ["-ffile-prefix-map=\(packageRoot)=/CLibMobi"]

// libmobi v0.12 的 C 源码，供 AZW3／MOBI 导入转换使用。来源、取舍与编译选项见 README.md。
let package = Package(
    name: "CLibMobi",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CLibMobi", type: .static, targets: ["CLibMobi"])
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
                .unsafeFlags(["-w"] + prefixMaps),
            ],
            // 未定义 USE_MINIZ 时 libmobi 使用系统 zlib 解压字体等资源。
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
