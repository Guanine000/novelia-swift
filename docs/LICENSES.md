# 许可与第三方软件

[← 返回 README](../README.md) · [功能说明](FEATURES.md) · [WebDAV 同步](WEBDAV.md) · [本机构建与分发](BUILD.md)

## 本项目许可

本仓库中由项目维护者拥有授权权利的 App 源代码和项目文档采用 **GNU GPL-3.0-only**（SPDX：`GPL-3.0-only`），完整条款见根目录 [LICENSE](../LICENSE)。本 iOS 项目是参考 [GPL-3.0-only 安卓客户端](https://github.com/nobYoQ/novelia) 制作的 Swift 移植版本，包含平台适配和后续修改；上游版权声明 `Copyright (C) 2026 Novelia Android contributors.` 予以保留。本 iOS 移植及新增部分版权声明为 `Copyright (C) 2026 Novelia iOS contributors.`，修改版本日期为 2026-10-26。

WebDAV 强版本读取、坚果云条件头兼容和首次创建流程参考并以 Swift 适配自安卓端 `WebDavClient.kt`，固定来源提交为 [44be26d](https://github.com/nobYoQ/novelia/blob/44be26d51e2a38e98aea74dc31aca1bb0a0261fe/app/src/main/java/cc/novelia/app/data/webdav/WebDavClient.kt)。保留上述安卓贡献者版权和 GPL-3.0-only 许可；适配部分见本仓库 `WebDAVRemote.swift`。未引入 Anx Reader、Joplin 或 restic 的代码与依赖。

第三方组件、YueduCoreText、用户导入字体、Novelia 网站内容、小说与用户内容仍分别适用其自身许可证或权利声明，不被本仓库的 GPL 声明替代或重新授权。完整第三方清单、许可文本和 YueduCoreText 对应源码见下方清单及最新 Release 附件。默认书本图标由维护者使用 GPT 生成并提供，随本项目源码和 IPA 分发；其他非代码资源仍以其各自权利状态为准。

## 第三方软件

App 在“我的 → 开源许可”提供第三方许可原文；仓库的[完整依赖清单](../iOSApp/Resources/ThirdPartyLicenses/INDEX.md)列出 `Package.resolved` 中全部 10 个 Swift Package 的版本、来源及许可文件，以及实验性 Readium EPUB 阅读器随附的字体与脚本声明。IPA 随附 Zip 内嵌 MiniZip / Info-ZIP 的独立版权与完整许可，以及这些原始许可文本、YueduCoreText 的 MPL-2.0 许可和包含 Unicode License v3 的 NOTICE。YueduCoreText 对应源码为[精确锁定的提交](https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe)，本项目没有修改该依赖的上游源码。用户自行导入的字体保存在本机 App 文档目录，不随本项目 IPA 分发；字体文件仍受其自身许可约束。

阅读器依赖的版本、用途与代码分类见[阅读器依赖](../iOSApp/Features/Reader/EPUBReader/DEPENDENCIES.md)。

**libmobi：** AZW3／MOBI 导入使用 [libmobi](https://github.com/bfabiszewski/libmobi) 0.12（LGPL-3.0-or-later）。其 C 源码位于 [`Vendor/CLibMobi/`](../Vendor/CLibMobi/README.md)，作为本地 Swift 包编译并静态链接，未修改上游源码，未收录 DRM 处理代码；许可原文随 App 提供（[libmobi-LICENSE.txt](../iOSApp/Resources/ThirdPartyLicenses/libmobi-LICENSE.txt)）。Kindle 导入测试样本取自 libmobi 自带的自生成样本，来源见 [`Tests/NoveliaKindleTests/Fixtures/README.md`](../Tests/NoveliaKindleTests/Fixtures/README.md)。

**TXT 分章参考：** [Qingdu Reader](https://github.com/zengchen666/qingdu-reader) 使用 Apache License 2.0。本项目仅参考其公开说明中的设计思路，分章识别器为独立 Swift 实现；没有复制、修改或随包分发 Qingdu Reader 的源代码、二进制或资源。Apache-2.0 原文见 [Qingdu Reader LICENSE](https://github.com/zengchen666/qingdu-reader/blob/main/LICENSE)。

## 对应源码与发布核对

最新 Release 附有本项目对应版本源码归档，以及 YueduCoreText 锁定提交的源码和许可材料。分发 IPA 时应同时提供同一版本的完整对应源码与第三方许可材料。构建流程使用 [`scripts/verify_third_party_notices.py`](../scripts/verify_third_party_notices.py) 核对锁定依赖、许可清单和原始文件，并检查许可资源是否进入 IPA。发布前还需运行 `python3 scripts/verify_release_privacy.py <IPA路径>`，检查包内是否包含开发者主目录路径或常见凭据特征。
