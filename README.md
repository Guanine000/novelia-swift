<div align="center">

<img src="Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Novelia iOS 图标">

# Novelia iOS

[轻小说机翻机器人](https://n.novelia.cc/)的第三方 iPhone 客户端

在 iPhone 上浏览、下载和阅读 Novelia 网络小说与文库

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)](#下载与安装)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-F05138?logo=swift&logoColor=white)](DEVELOPMENT.md)
[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/Guanine000/novelia-swift?label=release)](https://github.com/Guanine000/novelia-swift/releases/latest)

[下载最新版](https://github.com/Guanine000/novelia-swift/releases/latest) · [功能说明](docs/FEATURES.md) · [WebDAV 同步](docs/WEBDAV.md) · [本机构建](docs/BUILD.md) · [开发文档](DEVELOPMENT.md)

</div>

---

## 亮点

| | |
| --- | --- |
| 📚 **统一书库** | 导入的 TXT／EPUB 与下载的书籍集中管理，支持系列、来源筛选、搜索排序、批量操作与继续阅读 |
| 📖 **原生分页阅读** | YueduCoreText 单页／双页、跟手翻页与多字选取；可选实验性 Readium 引擎 |
| 🌐 **在线章节** | 原文、译文或逐段双语阅读，滚动与分页模式随时切换 |
| 🔍 **发现与社区** | 网络小说与文库搜索、热度榜、标签筛选与屏蔽；论坛、评论与收藏共用一个账号 |
| ☁️ **WebDAV 同步** | 手动或自动同步书籍、阅读进度、标签、阅读背景、字体和阅读时长；其他设备的书按需下载，多设备按时间合并 |
| 🎨 **个性化** | 字号、字体、间距、边距、阅读背景、主题色与自定义底栏 |
| 📊 **阅读统计** | 今日／本周／累计时长、7／30 天趋势、逐书与分设备记录，默认关闭 |

逐项说明见[功能说明](docs/FEATURES.md)。

## 下载与安装

[下载最新 Release](https://github.com/Guanine000/novelia-swift/releases/latest) · [查看发行记录](https://github.com/Guanine000/novelia-swift/releases)

> [!IMPORTANT]
> Release 附件是**未签名 IPA**，安装到常规真机前需要自行签名。最低系统版本为 **iOS 17**。

想从源码运行，请用 Xcode 打开 `NoveliaIOS.xcodeproj`，选择 `Novelia` scheme。测试、本机构建与分发流程见[本机构建与分发](docs/BUILD.md)。

## 已知限制

- Readium 阅读器仍为实验功能，默认关闭，需要更多真机验收。
- EPUB 排版、翻页、注脚等交互仍需在更多真机和真实书籍上验证；EPUB 书签和书内搜索尚未实现。
- 网络小说只提供 EPUB 整本下载；TXT 需从本地文件导入。
- WebDAV 要求 HTTPS，自动同步默认关闭且受 iOS 后台运行时间限制，建议以手动同步为主；普通本地删除保留云端副本，明确选择删除云端副本时会由新版设备同步处理，旧版不识别删除记录。

完整列表见[功能说明 → 已知限制](docs/FEATURES.md#已知限制)与 [WebDAV → 已知限制](docs/WEBDAV.md#已知限制)。

## 致谢

- 产品功能参考 [nobYoQ/novelia](https://github.com/nobYoQ/novelia)（GPL-3.0-only 安卓客户端）。
- Novelia 网站与 API 来自 [AutoNovel](https://github.com/auto-novel/auto-novel)。
- 阅读引擎：[YueduCoreText](https://github.com/CHANG-JUI-LIN/YueduCoreText)（MPL-2.0）、[Readium swift-toolkit](https://github.com/readium/swift-toolkit)（BSD-3-Clause）。
- TXT 分章设计参考 [Qingdu Reader](https://github.com/zengchen666/qingdu-reader)（Apache-2.0），本项目为独立 Swift 实现。

这些项目及网站内容分别适用各自的权利与许可条件。

## 许可

本仓库中由项目维护者拥有授权权利的 App 源代码和项目文档采用 **GNU GPL-3.0-only**（SPDX：`GPL-3.0-only`），完整条款见根目录 [LICENSE](LICENSE)。上游版权声明 `Copyright (C) 2026 Novelia Android contributors.` 予以保留；本 iOS 移植及新增部分版权声明为 `Copyright (C) 2026 Novelia iOS contributors.`。

第三方组件、YueduCoreText、用户导入字体、Novelia 网站内容、小说与用户内容仍分别适用其自身许可证或权利声明，不被本仓库的 GPL 声明替代或重新授权。分发 IPA 时应同时提供同一版本的完整对应源码与第三方许可材料。完整说明见[许可与第三方软件](docs/LICENSES.md)。

## 反馈

普通问题请通过 [Issues](https://github.com/Guanine000/novelia-swift/issues) 提交。公开反馈前请移除账号、令牌、WebDAV 凭据、私人书籍和个人信息。安全漏洞请通过[私密安全报告](https://github.com/Guanine000/novelia-swift/security/advisories/new)提交。
