# EPUB 阅读器依赖与许可清单

本文件登记 `iOSApp/EPUBReader/`（CoreText 原生 EPUB 分页阅读器）引入的第三方依赖：版本、许可证、来源与代码分类。更换版本时请同步更新此处、Xcode 工程与 `Package.swift`（测试目标 `NoveliaEPUB` 直接编译本目录的容器与分页源码）的固定版本。

## 第三方 Swift Package

| 包 | 锁定版本 | 许可证 | 来源 | 用途 |
| --- | --- | --- | --- | --- |
| YueduCoreText | **0.8.0（exact，Xcode 工程内固定）** | MPL-2.0 | https://github.com/CHANG-JUI-LIN/YueduCoreText | HTML/CSS 排版、分页（`BrowserLayoutSession`）、页面绘制（`DisplayListBuilder`）、CJK 排版 |
| ReadiumZIPFoundation | 3.0.1（upToNextMajor） | MIT | https://github.com/readium/ZIPFoundation | 自写 EPUB 容器解析所用的 ZIP 读取（该 fork 由 readium/ZIPFoundation 仓库发布，模块名 `ReadiumZIPFoundation`） |
| SwiftSoup | 2.13.7（由 YueduCoreText 精确依赖，未直接使用） | MIT | https://github.com/scinfu/SwiftSoup | YueduCoreText 的 HTML 解析后端（传递依赖） |
| Readium swift-toolkit | 3.11.0 | BSD-3-Clause | https://github.com/readium/swift-toolkit | 实验性 EPUB／TXT／在线分页阅读器（`ReadiumEPUBReaderModel/View.swift`、`ReadiumTextPublication.swift`，WKWebView + ReadiumCSS）；传递依赖 CryptoSwift、DifferenceKit、Fuzi、GCDWebServer、SQLite.swift、Zip，许可见 `iOSApp/Resources/ThirdPartyLicenses/INDEX.md` |

## 代码分类（新写 / 上游 / 修改）

- **新写（本项目原创，位于 `iOSApp/EPUBReader/`）**：
  - `EPUBContainer.swift` — 最小 EPUB 容器解析（ZIP/container.xml/OPF/spine/nav、CSS 与图片装载）。
  - `EPUBPageBook.swift` — 页面标识（generation × spineIndex × pageIndex）、排版缓存、页面位图渲染。
  - `EPUBPagerView.swift` — 左右相接、跟手平移的翻页视图（预览页与落页共用同一份位图）。
  - `EPUBReaderModel.swift` — 阅读状态、代次失效、跨章节与预取。
  - `EPUBReaderView.swift` — 阅读界面（目录、字号、翻页入口）。
  - `EPUBSampleBook.swift` — 可复现样例 EPUB 生成器，仅在 Debug 构建中编译。
- **上游**：仅通过 Swift Package Manager 以二进制源码形式引用上表依赖；**没有复制、嵌入或修改 YueduCoreText 或 Yuedu-reader 的任何源码文件**。
- **修改的上游文件**：无。仓库内对上游的唯一改动是 Xcode 工程的包引用配置（`project.pbxproj`）。

## 许可合规说明（分发 IPA 时）

1. **MPL-2.0（YueduCoreText）**：以库形式链接不要求整个 App 开源，但需：
   - 在 App 内或随附文档中保留 MPL-2.0 许可声明并注明 YueduCoreText 来源；
   - 若修改其源码再分发，修改的文件须以 MPL-2.0 提供。本项目未修改其源码。
   - 分发可执行文件时，须让接收者以合理方式取得对应 MPL 覆盖源码；本次锁定的准确提交和取得方式见应用随附的 `ThirdPartyLicenses/INDEX.md`。
2. **MIT（ReadiumZIPFoundation、SwiftSoup）**：保留版权与许可声明即可。
3. 许可不授予 Yuedu / Yuedu-reader 的商标、Logo 或其他品牌素材使用权；清单中为说明软件来源而列出项目名称。本阅读器未使用其图标或 Logo。
4. 书库导入时的 EPUB 元数据与封面提取由 `EPUBContainer` 完成；Readium swift-toolkit 3.11.0 用于实验性 EPUB、TXT 与在线小说分页阅读器。TXT／在线适配器为本项目原创，通过公开 Publication／Container API 接入，没有复制或修改上游文件。Zip 内嵌 MiniZip / Info-ZIP 的独立许可与来源声明一并随包提供。

## 验证记录

- 版本与许可核对日期：2026-10-08（对照各上游仓库的 Package.swift 与 LICENSE 文件）。
- `Package.resolved` 由首次模拟器构建生成，构建通过后以仓库内实际 resolved 文件为准。

## 应用级许可分发（2026-10-08 更新）

上表只记录 EPUB 阅读器直接涉及的包。整个 App 的 **10 个锁定 Swift Package**、版本、许可证、源码地址及完整原始许可文件见 [`../Resources/ThirdPartyLicenses/INDEX.md`](../Resources/ThirdPartyLicenses/INDEX.md)。这些文本作为 Xcode 文件夹资源打入 IPA，并在“我的 → 开源许可”中可查看。YueduCoreText 的原始 `NOTICE`（含 Unicode License v3）一并提供。发布流水线检查全部文件确实进入 IPA。
