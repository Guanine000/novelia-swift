<div align="center">

<img src="Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Novelia iOS 图标">

# Novelia iOS

[轻小说机翻机器人](https://n.novelia.cc/)的第三方 iPhone 客户端

在 iPhone 上浏览、下载和阅读 Novelia 网络小说与文库

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)](#下载与安装)
[![iOS 15 Readium](https://img.shields.io/badge/iOS%2015-Readium-555555?logo=apple&logoColor=white)](#下载与安装)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-F05138?logo=swift&logoColor=white)](DEVELOPMENT.md)
[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/Guanine000/novelia-swift?label=release)](https://github.com/Guanine000/novelia-swift/releases/latest)

[下载最新版](https://github.com/Guanine000/novelia-swift/releases/latest) · [功能说明](docs/FEATURES.md) · [WebDAV 同步](docs/WEBDAV.md) · [本机构建](docs/BUILD.md) · [开发文档](DEVELOPMENT.md)

</div>

---

## 亮点

| | |
| --- | --- |
| 📚 **统一书库** | 导入的 TXT／EPUB（AZW3／MOBI 转换为 EPUB 后导入）与下载的书籍集中管理，支持系列、来源筛选、搜索排序、分组操作菜单、批量操作（含压缩后分享）与继续阅读；文库和导入书籍可编辑书名、作者、简介与封面 |
| 📖 **原生分页阅读** | YueduCoreText 单页／双页、跟手翻页与多字选取，书签与书内搜索；可选实验性 Readium 引擎。iOS 15 安装包没有原生分页，固定使用 Readium |
| 🔊 **朗读** | 本地系统／Readium TTS 与可选 Edge 在线语音（默认关闭），书内切换引擎、选句起播与高亮、独立音量音高、动态音色与试听、快捷控制、可选预合成及锁屏定时 |
| 🌐 **在线章节** | 原文、译文或逐段双语阅读，滚动与分页模式随时切换，支持按章离线缓存 |
| 🔍 **发现与社区** | 网络小说与文库搜索、热度榜、标签筛选与屏蔽；论坛、评论与收藏共用一个账号 |
| ☁️ **WebDAV 同步** | 手动或自动同步书籍、书签、书库信息、阅读进度、标签、阅读背景、字体和阅读时长；其他设备的书按需下载；网络小说更新时沿用已确认的下载设置（旧记录缺失时先选择），本地承接已确认章节，在书库更多菜单核对后可跨 EPUB 版本同步进度与书签，多设备按时间合并 |
| 🎨 **个性化** | 单书字号、字体、间距、边距、阅读主题、简繁与文字替换、自定义底栏 |
| 📊 **阅读统计** | 今日／本周／累计时长、7／30 天趋势、逐书与分设备记录，默认关闭 |

逐项说明见[功能说明](docs/FEATURES.md)。

书签添加或删除会先保存到本机，保存失败时提示重试；开启自动同步后，书签改动也会触发延迟同步。同步期间的新修改会保留为待同步内容，详细行为见 [WebDAV 同步](docs/WEBDAV.md#自动同步)。

## 下载与安装

[下载最新正式版](https://github.com/Guanine000/novelia-swift/releases/latest) · [查看预发布测试版与发行记录](https://github.com/Guanine000/novelia-swift/releases)

> [!IMPORTANT]
> Release 附件是**未签名 IPA**，安装到常规真机前需要自行签名。双安装包分别为：`Novelia` 面向 **iOS 17**，默认使用 YueduCoreText 原生分页；文件名含 `ios15` 的 `NoveliaLegacy`（bundle id `cc.novelia.ios.port.ios15`，主屏幕名称为 Novelia 15）面向 **iOS 15**，分页固定为 Readium，不能切回原生分页，也不导入 AZW3／MOBI。
>
> **iOS 15 Legacy 版还没有在真实 iOS 15／16 上运行验证。** 已通过编译与自动化检查，但旧系统实际运行和真实书籍完整回归仍待验证。

想从源码运行，请用 Xcode 打开 `NoveliaIOS.xcodeproj`。iOS 17 选择 `Novelia` scheme，iOS 15 选择 `NoveliaLegacy` scheme。测试、本机构建与分发流程见[本机构建与分发](docs/BUILD.md)。

参与开发前请阅读[开发文档](DEVELOPMENT.md)，了解模块职责、服务与本地状态的依赖注入、文件读写及数据兼容约定；发布流程包含架构依赖与书库事务故障检查；性能测量方法见[性能基线与故障验收](docs/PERFORMANCE.md)。

## 已知限制

- Readium 阅读器在 iOS 17 安装包中仍为实验功能，默认关闭，需要更多真机验收。iOS 15 安装包只能使用 Readium。
- EPUB 排版、翻页、注脚等交互仍需在更多真机和真实书籍上验证。
- 网络小说只提供 EPUB 整本下载；TXT 需从本地文件导入。
- WebDAV 要求 HTTPS；自动同步默认关闭且受 iOS 后台运行时间限制，建议以手动同步为主；只删除本机时保留云端副本。
- 从云端删除书籍时一并删除不再被引用的云端文件；若另一台设备恰在同时同步同一内容，该文件可能缺失，在仍有副本的设备上手动同步即可补传，见 [WebDAV 说明](docs/WEBDAV.md#从云端删除)。

完整列表见[功能说明 → 已知限制](docs/FEATURES.md#已知限制)与 [WebDAV → 已知限制](docs/WEBDAV.md#已知限制)；多台设备版本不同时见 [WebDAV → 与旧版本混用](docs/WEBDAV.md#与旧版本混用)。

账号登录在 App 内打开 Novelia 官网，由官网处理账号密码；登录成功后建立小说与论坛会话。

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
