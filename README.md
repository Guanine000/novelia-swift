# Novelia iOS

一个以 SwiftUI 编写的 iOS 客户端，连接 Novelia 网站，支持网络小说浏览与阅读，以及文库 EPUB 下载和导出。`prototype/yuedu-coretext-pager` 分支另提供原生 CoreText EPUB 阅读预览版。

本项目参考第三方 Android 客户端 [nobYoQ/novelia](https://github.com/nobYoQ/novelia) 的功能，并使用 [AutoNovel](https://github.com/auto-novel/auto-novel) 提供的网站与 API 服务。iOS 客户端独立开发，不会修改上述仓库。

## 版本与下载

**正式版：[v0.4.1](https://github.com/Guanine000/novelia-ios-port/releases/tag/v0.4.1)** · **EPUB 阅读预览版：[v0.4.1-coretext-preview.1](https://github.com/Guanine000/novelia-ios-port/releases/tag/v0.4.1-coretext-preview.1)** · 最低支持 iOS 17

[查看全部 Release](https://github.com/Guanine000/novelia-ios-port/releases) · [查看构建记录](https://github.com/Guanine000/novelia-ios-port/actions)

两个 Release 均提供未签名 IPA，需自行签名后才能安装到常规真机。预览版附件 `Novelia-unsigned.ipa` 对应提交 `f8655e1`，SHA-256 为 `b638110a1d7bf06aa52a51e612f076d160a26da2d61471206cf177563291d82b`。

正式版 v0.4.1 将网络小说下载切换为 Novelia 官网整本 EPUB 接口，支持选择原文或译源；下载文件可在“我的下载”中导出。正式版不提供应用内 EPUB 阅读和导入。预览版从 `prototype/yuedu-coretext-pager` 分支构建，加入下述 EPUB 阅读原型；该分支最新改动尚未合并 `main`。预览版 App 内版本仍显示 `0.4.1 (5)`，请以 Release 标签和附件校验值区分构建。

## EPUB 阅读预览版

预览版使用 [YueduCoreText 0.8.0](https://github.com/CHANG-JUI-LIN/YueduCoreText) 排版；EPUB 容器、目录、资源装载和阅读界面由本项目实现。可从“我的下载”打开已下载的 EPUB，或使用导入按钮从“文件”选择 EPUB。当前阅读页包含全屏正文、左右相接的跟手平移翻页、目录与当前章节高亮、注脚弹层、字号调节、跟随系统深浅色，以及可拖动的全书进度条。

针对已遇到的真实 EPUB，原型还处理章节相对资源路径、EPUB 2 NCX / EPUB 3 nav、图片与 ruby、部分 Kindle / 多看样式；对 CSS4 透明十六进制颜色及部分 `@media` 条件提供宿主回退。完整实现与依赖清单见 [`iOSApp/EPUBPrototype/DEPENDENCIES.md`](iOSApp/EPUBPrototype/DEPENDENCIES.md)，迭代和验证记录见 [`EPUB_READER_REPORT.md`](EPUB_READER_REPORT.md)。

**预览版仍待真机验收**：Files 导入、连续及跨章翻页、目录跳转、注脚点击、进度条拖动和复杂样式需用真实 EPUB 检查。全书百分比按章节近似估算；同章锚点尚不能精确定位；`text-shadow` 目前以文字颜色近似。仿真翻页、EPUB 阅读位置持久化和书签尚未实现。

## 功能

| 模块 | 已支持 |
| --- | --- |
| 发现 | 搜索在线小说和文库作品；滚动加载更多结果；按标签筛选；查看 Novelia 站内点击热度榜。 |
| 网络小说 | 查看作品详情、标签、字数、章节和译源进度；选择翻译源；阅读原文、译文或逐段双语内容；调用 Novelia 官网整本接口下载 EPUB。 |
| 书架 | 登录后读取 Novelia 云端网络小说收藏和文库收藏；首页展示最近阅读与收藏；从作品详情继续阅读。 |
| 阅读 | 查看目录并跳转章节；切换浅色、深色或跟随系统；调整字号；保存章节阅读进度和书签。 |
| 评论 | 查看网络小说和文库的 Novelia 网页评论、回复；登录后发表评论和回复。 |
| 我的下载 | 在“网络小说 / 文库”之间切换；导出或删除网络小说 EPUB 和文库 EPUB。 |
| 文库 EPUB | 查看作品分卷与各译源可用章节；选择译文或双语 EPUB 及翻译源；下载后可在“我的下载”中导出或删除。 |
| 账号与诊断 | 通过 Novelia 统一认证登录；从“我的”页面导出应用日志。 |

收藏、评论和账号数据使用 Novelia 网站服务。网络小说与文库收藏分开管理。文库 EPUB 下载使用上游提供的译文，原文单独下载当前受上游接口限制。

## 尚未支持

- v0.4.1 Release 不提供应用内 EPUB 阅读和导入；预览版提供上述原型。TXT / SRT 本地阅读尚未实现。
- WebDAV 同步、云端书架文件夹管理、云端阅读进度双向同步。
- 网络书源切换、高级搜索、书签和笔记管理、书内搜索及朗读。
- 论坛内容流与发帖、后台下载队列、备份恢复和应用内更新。

## 下载与版本

前往 [GitHub Releases](https://github.com/Guanine000/novelia-ios-port/releases) 查看已发布版本、发行说明和 IPA。推送到 `main` 会触发 **Build iOS IPA** 工作流；其他分支可在 GitHub Actions 页面手动选择分支运行。完成后可从运行记录的 **Artifacts** 下载 `Novelia-unsigned.ipa`。

项目版本号在 Xcode 工程的 `MARKETING_VERSION` 中维护，并显示在 App 的“我的 → 版本”页面。当前预览版未提升该字段，仍显示 `0.4.1 (5)`。Release 和每次 Actions 构建均会保留各自的产物记录。

## 在 Xcode 中运行

1. 使用 Xcode 打开 `NoveliaIOS.xcodeproj`。
2. 选择 `Novelia` scheme 和 iOS 模拟器。
3. 运行项目，或按 **⌘R**。

要运行本次 EPUB 阅读预览版，先切换到 `prototype/yuedu-coretext-pager` 分支。原型的前 20 轮已合并到 `main`，但最新的样式兼容和可拖动进度条只在该分支及预览版 Release 中。可在“我的下载”中进入阅读原型，也可用启动参数 `-openEPUBPrototype` 打开调试样例书。

项目最低部署版本为 iOS 17。Xcode 使用 Swift Package Manager 管理依赖。`Package.swift` 提供平台无关的 `NoveliaIOSCore` 模型和样例数据。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `iOSApp/` | SwiftUI 界面、阅读器、文库 EPUB 下载与导出、账号认证。 |
| `iOSApp/EPUBPrototype/` | 预览分支中的 EPUB 容器解析、CoreText 分页、阅读界面、样例书和依赖许可清单。 |
| `Sources/NoveliaIOSCore/` | Novelia API 客户端、网络与文库模型、Keychain 令牌存储。 |
| `NoveliaIOS.xcodeproj/` | Xcode 工程和应用构建设置。 |

## 开源与移植范围

本项目是独立的 Swift 实现。Android 对照项目采用 GPL-3.0-only；AutoNovel 网站/API 仓库、第三方依赖和网站内容分别适用各自的许可证或权利声明。若后续复用上游代码或资源进行分发，请先核对对应条款。

EPUB 预览版通过 Swift Package Manager 精确锁定 YueduCoreText 0.8.0（MPL-2.0），未复制或修改 YueduCoreText / Yuedu-reader 源码，也未使用其品牌素材。分发时的依赖和 MPL 说明义务记录在 [`DEPENDENCIES.md`](iOSApp/EPUBPrototype/DEPENDENCIES.md)。
