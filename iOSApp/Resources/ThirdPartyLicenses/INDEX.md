# 第三方软件许可

本应用使用以下 Swift Package。版本以项目 Package.resolved 为准。下列文件保留各包原始许可声明；YueduCoreText 的 NOTICE 同时包含 Unicode License v3。

| 软件包 | 版本 | 许可证 | 源码 | 许可文件 |
| --- | --- | --- | --- | --- |
| SwiftSoup | 2.13.7 | MIT | https://github.com/scinfu/SwiftSoup | [SwiftSoup-LICENSE.txt](SwiftSoup-LICENSE.txt) |
| YueduCoreText | 0.8.0 | MPL-2.0 | https://github.com/CHANG-JUI-LIN/YueduCoreText | [YueduCoreText-LICENSE.txt](YueduCoreText-LICENSE.txt) |
| ZIPFoundation | 3.0.1 | MIT | https://github.com/readium/ZIPFoundation | [ZIPFoundation-LICENSE.txt](ZIPFoundation-LICENSE.txt) |
| swift-toolkit | 3.11.0 | BSD-3-Clause | https://github.com/readium/swift-toolkit | [swift-toolkit-LICENSE.txt](swift-toolkit-LICENSE.txt) |
| CryptoSwift | 1.10.0 | CryptoSwift License (zlib-style, attribution) | https://github.com/krzyzanowskim/CryptoSwift | [CryptoSwift-LICENSE.txt](CryptoSwift-LICENSE.txt) |
| DifferenceKit | 1.3.0 | Apache-2.0 | https://github.com/ra1028/DifferenceKit | [DifferenceKit-LICENSE.txt](DifferenceKit-LICENSE.txt) |
| Fuzi | 4.0.1 | MIT | https://github.com/readium/Fuzi | [Fuzi-LICENSE.txt](Fuzi-LICENSE.txt) |
| GCDWebServer | 4.0.1 | BSD-3-Clause | https://github.com/readium/GCDWebServer | [GCDWebServer-LICENSE.txt](GCDWebServer-LICENSE.txt) |
| SQLite.swift | 0.16.0 | MIT | https://github.com/stephencelis/SQLite.swift | [SQLite.swift-LICENSE.txt](SQLite.swift-LICENSE.txt) |
| Zip | 2.1.2 | MIT | https://github.com/marmelroy/Zip | [Zip-LICENSE.txt](Zip-LICENSE.txt) |

YueduCoreText 另附 [NOTICE](YueduCoreText-NOTICE.txt)。swift-toolkit（Readium）及其后六项为实验性 Readium EPUB 阅读器引入的依赖，均未修改上游源码。

This product includes software developed by the "Marcin Krzyzanowski" (http://krzyzanowskim.com/).（CryptoSwift 许可要求的致谢）

## Readium 随附的字体与脚本

swift-toolkit 3.11.0 的资源包随 App 分发以下第三方内容：

| 内容 | 许可证 | 许可文件 |
| --- | --- | --- |
| ReadiumCSS 字体 AccessibleDfA | SIL OFL 1.1 | [ReadiumCSS-AccessibleDfA-LICENSE.txt](ReadiumCSS-AccessibleDfA-LICENSE.txt) |
| ReadiumCSS 字体 iA Writer Duospace（IBM Plex） | SIL OFL 1.1 | [ReadiumCSS-iAWriterDuospace-LICENSE.txt](ReadiumCSS-iAWriterDuospace-LICENSE.txt) |
| OpenDyslexic 2.001 | Bitstream Vera License；改动部分 CC BY 3.0 | [OpenDyslexic-LICENSE.txt](OpenDyslexic-LICENSE.txt) |
| 阅读器脚本中打包的 Hypothesis 代码与 92 个 npm 包 | BSD-2-Clause、MIT、Apache-2.0 | [Readium-JavaScript-NOTICES.txt](Readium-JavaScript-NOTICES.txt) |
本应用的 EPUB 原型代码为本项目新写，通过 Swift Package Manager 使用 YueduCoreText 公开 API；未修改上游文件。

## YueduCoreText 对应源码

本应用使用的 YueduCoreText 0.8.0 精确锁定至提交 `783ce903d5faf4ff5d15c546e32a107537ba5efe`。其 MPL-2.0 覆盖源码可从 [上游对应提交](https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe) 获取；若该链接不可用，请联系本项目维护者取得本次分发对应的源码。许可正文见上方 `YueduCoreText-LICENSE.txt`。
