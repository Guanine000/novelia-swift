# EPUB 阅读器依赖与许可清单

本文件登记 `iOSApp/Features/Reader/EPUBReader/`（Yuedu 原生分页与 Readium 阅读器）引入的第三方依赖：版本、许可证、来源与代码分类。更换版本时请同步更新此处、Xcode 工程与 `Package.swift`（测试目标 `NoveliaEPUB` 直接编译本目录的容器与分页源码）的固定版本。

## 第三方 Swift Package

| 包 | 锁定版本 | 许可证 | 来源 | 用途 |
| --- | --- | --- | --- | --- |
| YueduCoreText | **0.8.0（exact，Xcode 工程内固定）** | MPL-2.0 | https://github.com/CHANG-JUI-LIN/YueduCoreText | HTML/CSS 排版、分页（`BrowserLayoutSession`）、页面绘制（`DisplayListBuilder`）、CJK 排版 |
| ReadiumZIPFoundation | 3.0.1（解析版本以锁定文件为准） | MIT | https://github.com/readium/ZIPFoundation | 自写 EPUB 容器解析所用的 ZIP 读取（该 fork 由 readium/ZIPFoundation 仓库发布，模块名 `ReadiumZIPFoundation`） |
| SwiftSoup | 2.13.7（由 YueduCoreText 精确依赖，未直接使用） | MIT | https://github.com/scinfu/SwiftSoup | YueduCoreText 的 HTML 解析后端（传递依赖） |
| Readium swift-toolkit | 3.11.0 | BSD-3-Clause | https://github.com/readium/swift-toolkit | 实验性 EPUB／TXT／在线分页阅读器（`ReadiumEPUBReaderModel/View.swift`、`ReadiumTextPublication.swift`，WKWebView + ReadiumCSS）；传递依赖 CryptoSwift、DifferenceKit、Fuzi、GCDWebServer、SQLite.swift、Zip，许可见 `iOSApp/Resources/ThirdPartyLicenses/INDEX.md` |

## 本项目代码与上游依赖

- **本项目实现（位于 `iOSApp/Features/Reader/EPUBReader/`）**：
  - `EPUBContainer.swift` — 最小 EPUB 容器解析（ZIP/container.xml/OPF/spine/nav、CSS 与图片装载）。
  - `EPUBPageBook.swift` — 页面标识（generation × spineIndex × pageIndex）、排版缓存、页面位图渲染。
  - `EPUBPagerView.swift` — 左右相接、跟手平移的翻页视图（预览页与落页共用同一份位图）。
  - `EPUBReaderModel.swift` — 阅读状态、代次失效、跨章节与预取。
  - `EPUBReaderView.swift` — 阅读界面（目录、字号、翻页入口）。
  - `EPUBChapterSource.swift` — EPUB、TXT 与在线内容的章节接口及文本适配。
  - `EPUBLayoutCoordinator.swift` — 排版请求合并和结果缓存。
  - `ReadiumEPUBReaderModel.swift`、`ReadiumEPUBReaderView.swift` — Readium 导航、界面和阅读进度连接。
  - `ReadiumTextPublication.swift` — 惰性文本 Publication 与导航索引。
  - `EPUBSampleBook.swift` — 可复现样例 EPUB 生成器，仅在 Debug 构建中编译。
- **上游**：通过 Swift Package Manager 引入并编译上表依赖源码；**没有复制、嵌入或修改 YueduCoreText 或 Yuedu-reader 的任何源码文件**。
- **修改的上游文件**：无。包引用与版本配置由 Xcode 工程、`Package.swift` 和锁定文件管理，宿主适配不等于修改上游源码。

## 许可合规说明（分发 IPA 时）

1. **MPL-2.0（YueduCoreText）**：以库形式链接不要求整个 App 开源，但需：
   - 在 App 内或随附文档中保留 MPL-2.0 许可声明并注明 YueduCoreText 来源；
   - 若修改其源码再分发，修改的文件须以 MPL-2.0 提供。本项目未修改其源码。
   - 分发可执行文件时，须让接收者以合理方式取得对应 MPL 覆盖源码；锁定的准确提交和取得方式见应用随附的[许可索引](../../../Resources/ThirdPartyLicenses/INDEX.md#yueducoretext-对应源码)。
2. **MIT（ReadiumZIPFoundation、SwiftSoup）**：保留版权与许可声明即可。
3. 许可不授予 Yuedu / Yuedu-reader 的商标、Logo 或其他品牌素材使用权；清单中为说明软件来源而列出项目名称。本阅读器未使用其图标或 Logo。
4. 书库导入时的 EPUB 元数据与封面提取由 `EPUBContainer` 完成；Readium swift-toolkit 3.11.0 用于实验性 EPUB、TXT 与在线小说分页阅读器。TXT／在线适配器为本项目原创，通过公开 Publication／Container API 接入，没有复制或修改上游文件。Zip 内嵌 MiniZip / Info-ZIP 的独立许可与来源声明一并随包提供。

## 依赖维护

项目锁定文件为 `NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。本表仅列阅读器主要依赖，完整解析版本与传递依赖以该文件和许可索引为准。

升级、替换或修改依赖时核对 API、资源、最低系统版本、许可、NOTICE 和对应源码要求；同步工程与测试目标的版本配置、许可清单和发布检查。运行相关阅读器/排版回归后，使用 `scripts/verify_third_party_notices.py` 核对实际 checkout 与包内许可资源。不能通过删除许可声明来解决检查失败。

## 应用级许可分发

整个 App 的锁定 Swift Package、版本、许可证、源码地址及完整原始许可文件见[第三方许可索引](../../../Resources/ThirdPartyLicenses/INDEX.md)。这些文本作为 Xcode 文件夹资源打入 IPA，并在“我的 → 开源许可”中展示。YueduCoreText 的 NOTICE（含 Unicode License v3）、Readium 随附字体/脚本，以及 Zip 内嵌 MiniZip / Info-ZIP 的声明一并保留。

项目代码与文档采用 GPL-3.0-only，第三方组件各自适用其许可证。IPA 分发提供对应项目源码、锁定依赖源码及许可材料；Readium 脚本的 npm 源码与补充构建材料由本地发布流程配套提供。发布流程见[本机构建与分发](../../../../docs/BUILD.md)，实现与维护边界见[开发文档](../../../../DEVELOPMENT.md#阅读器实现)。
