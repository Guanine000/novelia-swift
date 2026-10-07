# Novelia iOS

一个以 SwiftUI 编写的 iOS 客户端，连接 Novelia 网站，支持网络小说浏览与阅读，以及文库 EPUB 下载和导出。

本项目参考第三方 Android 客户端 [nobYoQ/novelia](https://github.com/nobYoQ/novelia) 的功能，并使用 [AutoNovel](https://github.com/auto-novel/auto-novel) 提供的网站与 API 服务。iOS 客户端独立开发，不会修改上述仓库。

## 当前版本

**v0.4.1** · 最低支持 iOS 17

[查看 GitHub Release 与下载 IPA](https://github.com/Guanine000/novelia-ios-port/releases/tag/v0.4.1) · [查看构建记录](https://github.com/Guanine000/novelia-ios-port/actions)

当前 Release 提供 GitHub Actions 构建的未签名 IPA。此文件需自行签名后才能安装到常规真机或提交 App Store。

v0.4.1 将网络小说下载切换为 Novelia 官网整本 EPUB 接口，支持选择原文或译源；下载文件可在“我的下载”中导出。另包含网页阅读滚动优化及文库 EPUB 下载文件管理调整。应用内 EPUB 阅读和导入目前不提供。

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

- 应用内 EPUB 阅读、导入 EPUB，以及 TXT / SRT 本地阅读。
- WebDAV 同步、云端书架文件夹管理、云端阅读进度双向同步。
- 网络书源切换、高级搜索、书签和笔记管理、书内搜索及朗读。
- 论坛内容流与发帖、后台下载队列、备份恢复和应用内更新。

## 下载与版本

前往 [GitHub Releases](https://github.com/Guanine000/novelia-ios-port/releases) 查看已发布版本、发行说明和 IPA。推送到 `main` 会触发 **Build iOS IPA** 工作流，也可在 GitHub Actions 页面手动运行；完成后可从运行记录的 **Artifacts** 下载 `Novelia-unsigned.ipa`。

项目版本号在 Xcode 工程的 `MARKETING_VERSION` 中维护，并显示在 App 的“我的 → 版本”页面。Release 和每次 Actions 构建均会保留各自的产物记录。

## 在 Xcode 中运行

1. 使用 Xcode 打开 `NoveliaIOS.xcodeproj`。
2. 选择 `Novelia` scheme 和 iOS 模拟器。
3. 运行项目，或按 **⌘R**。

项目最低部署版本为 iOS 17。Xcode 使用 Swift Package Manager 管理依赖。`Package.swift` 提供平台无关的 `NoveliaIOSCore` 模型和样例数据。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `iOSApp/` | SwiftUI 界面、阅读器、文库 EPUB 下载与导出、账号认证。 |
| `Sources/NoveliaIOSCore/` | Novelia API 客户端、网络与文库模型、Keychain 令牌存储。 |
| `NoveliaIOS.xcodeproj/` | Xcode 工程和应用构建设置。 |

## 开源与移植范围

本项目是独立的 Swift 实现。Android 对照项目采用 GPL-3.0-only；AutoNovel 网站/API 仓库、第三方依赖和网站内容分别适用各自的许可证或权利声明。若后续复用上游代码或资源进行分发，请先核对对应条款。
