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

Zip 内嵌 MiniZip（zlib）与 Info-ZIP 衍生加密代码，独立版权与完整许可见 [Zip-MiniZip-NOTICE.txt](Zip-MiniZip-NOTICE.txt)；Zip 根目录 MIT 不替代这些子组件的许可。

YueduCoreText 另附 [NOTICE](YueduCoreText-NOTICE.txt)。swift-toolkit（Readium）及其后六项为实验性 Readium EPUB 阅读器引入的依赖，均未修改上游源码。

This product includes software developed by the "Marcin Krzyzanowski" (http://krzyzanowskim.com/).（CryptoSwift 许可要求的致谢）

## C 库

| 软件 | 版本 | 许可证 | 源码 | 许可文件 |
| --- | --- | --- | --- | --- |
| libmobi | 0.12 | LGPL-3.0-or-later | https://github.com/bfabiszewski/libmobi | [libmobi-LICENSE.txt](libmobi-LICENSE.txt) |

libmobi 用于导入 AZW3／MOBI 时解析并转换为 EPUB，以源码形式随本项目提供（仓库 `Vendor/CLibMobi/`，对应上游提交 `85dcfe803fc2a21020ddcf15c3eb66b93d388add`），未修改上游源码，未收录其 DRM 处理代码。libmobi 静态链接进 App；本项目完整对应源码随分发提供，可据此替换 libmobi 后重新构建。LGPL-3.0 以 GPL-3.0 为基础，GPL 全文见 [GPL-3.0-only.txt](GPL-3.0-only.txt)。

## Readium 随附的字体与脚本

swift-toolkit 3.11.0 的资源包随 App 分发以下第三方内容：

| 内容 | 许可证 | 许可文件 |
| --- | --- | --- |
| ReadiumCSS 字体 AccessibleDfA | SIL OFL 1.1 | [ReadiumCSS-AccessibleDfA-LICENSE.txt](ReadiumCSS-AccessibleDfA-LICENSE.txt) |
| ReadiumCSS 字体 iA Writer Duospace（IBM Plex） | SIL OFL 1.1 | [ReadiumCSS-iAWriterDuospace-LICENSE.txt](ReadiumCSS-iAWriterDuospace-LICENSE.txt) |
| OpenDyslexic 2.001 | Bitstream Vera License；改动部分 CC BY 3.0 | [OpenDyslexic-LICENSE.txt](OpenDyslexic-LICENSE.txt) |
| 阅读器脚本中打包的 Hypothesis 代码与 92 个 npm 包 | BSD-2-Clause、MIT、Apache-2.0 | [Readium-JavaScript-NOTICES.txt](Readium-JavaScript-NOTICES.txt) |

阅读器脚本是压缩后的打包文件。Release 的依赖源码包包含 swift-toolkit 的脚本源码与 pnpm 锁定文件，以及打包所用全部 npm 包的原始发布包（`swift-toolkit-npm-sources/`，按锁定文件中的 SHA-512 完整性校验）。
依赖源码附件另包含 `npm-preferred-sources/`，提供 @juggle/resize-observer 3.4.0 和 approx-string-match 1.1.0 在 npm 发布包中缺少的 TypeScript 实现、构建配置及精确来源/校验清单。
本应用的 EPUB 原型代码为本项目新写，通过 Swift Package Manager 使用 YueduCoreText 公开 API；未修改上游文件。

## YueduCoreText 对应源码

本应用使用的 YueduCoreText 0.8.0 精确锁定至提交 `783ce903d5faf4ff5d15c546e32a107537ba5efe`。其 MPL-2.0 覆盖源码可从 [上游对应提交](https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe) 获取；若该链接不可用，请联系本项目维护者取得本次分发对应的源码。许可正文见上方 `YueduCoreText-LICENSE.txt`。

## Novelia 安卓参考实现

WebDAV 强版本读取与坚果云首次创建流程参考并适配自 Novelia 安卓端 `WebDavClient.kt`（提交 `44be26d51e2a38e98aea74dc31aca1bb0a0261fe`，GPL-3.0-only）。Copyright (C) 2026 Novelia Android contributors. Swift 平台适配与修改日期：2026-10-17。源码来源与修改范围见项目 `docs/LICENSES.md`；完整许可见 [GPL-3.0-only.txt](GPL-3.0-only.txt)。
