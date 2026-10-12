# Novelia iOS

本项目为[轻小说机翻机器人](https://n.novelia.cc/)的第三方客户端。

Novelia iOS 是使用 SwiftUI 编写的 iPhone 客户端，连接 Novelia 网站浏览网络小说与文库、阅读章节、管理收藏和下载 EPUB，并支持导入 TXT / EPUB 文件。项目还提供基于 YueduCoreText 的原生 EPUB 分页阅读器。最低系统版本为 **iOS 17**。

本项目参考 [nobYoQ/novelia](https://github.com/nobYoQ/novelia) 的产品功能；Novelia 网站与 API 来自 [AutoNovel](https://github.com/auto-novel/auto-novel)。这些项目及网站内容分别适用各自的权利与许可条件。

可在书籍详情页的「选择标签屏蔽」菜单里勾选屏蔽或解除标签（网络小说与文库详情页均支持），也可在“我的 → 标签屏蔽”手动添加或解除。WebDAV 可独立开启书籍同步（下载文件与阅读进度）、标签同步、阅读背景同步和导入字体同步。屏蔽设置可通过手动 WebDAV 同步，按每个标签最后修改时间合并，解除屏蔽也会同步。屏蔽应用于在线发现、搜索和排行榜，保留书架、收藏及下载；文库列表缺少标签，只能过滤本机已查看详情的作品。

阅读背景可分别设置浅色、深色模式的自定义颜色或图片，支持照片选择和文件导入，应用于在线小说、TXT和EPUB。入口为“我的 → 阅读背景”，设置和图片保存在本机，也可通过WebDAV独立开启阅读背景同步；浅深色分别支持竖屏与横屏图片。导入字体也可独立开启WebDAV同步。

## 功能

| 模块 | 当前能力 |
| --- | --- |
| 发现与作品 | 搜索网络小说和文库，网络小说书源没有匹配结果时用文库结果兜底；筛选标签、查看站内热度榜与作品详情，作品详情显示原名，网络小说与文库详情可互相跳转。 |
| 账号与书架 | 使用 Novelia 统一认证；读取网络小说和文库收藏、最近阅读与阅读历史。 |
| 论坛 | 浏览论坛分类与帖子，小说讨论支持按书单、工具、教程、资源标签筛选；三个分类均可按最近活跃、最新发布、最新更新、浏览最多或评论最多排序；搜索帖子、查看详情与回复；使用同一 Novelia 账号登录小说与论坛，支持发帖、评论、回复和收藏。 |
| 在线章节 | 原文、译文或逐段双语阅读；章节目录、阅读进度、书签、字号和深浅色设置；正文中的 HTTP/HTTPS 链接以带下划线的链接样式呈现，可点按打开。 |
| 评论 | 查看网络小说与文库的网页评论和回复；登录后发表与回复。 |
| EPUB 下载 | 使用 Novelia 官网整本接口下载网络小说 EPUB；下载文库译文或双语 EPUB；在“我的下载”中导出或删除。 |
| 本地书籍导入 | 在“我的下载”中从“文件”多选导入 EPUB 和 TXT；浮窗显示批量处理进度，完成后加入本地书籍列表，可阅读、导出或删除。 |
| EPUB 阅读 | 从“我的下载”打开 EPUB；解析 EPUB 2 NCX / EPUB 3 nav、图片与部分 ruby；左右相接的跟手平移翻页、单页/双页模式、多字拖选与复制/查询/网页搜索/分享、目录跳转、注脚弹层、书内链接、可拖动进度条；目录提供可折叠、可复制的解析与排版诊断。 |
| TXT 导入与阅读 | 从“文件”多选导入 TXT；本地阅读支持常见中英文标题分章、卷标题、章节目录、字号与主题设置。“我的 → 阅读体验 → TXT 分章规则”可启停内置规则，并添加、编辑或删除自定义整行正则。分章规则设计参考 [Qingdu Reader](https://github.com/zengchen666/qingdu-reader)（Apache-2.0），本项目为独立 Swift 实现。 |
| 阅读样式 | 设置字号、字体、行间距、段落间距、首行缩进和四边边距；恢复默认；从“文件”导入 TTF/OTF/TTC，并在管理页选用或删除。 |
| WebDAV 同步 | 在“我的 → WebDAV 同步”启用并配置 HTTPS WebDAV；在“我的下载”点同步开始，同步中再次点按可查看进度或取消；按书籍的下载/导入时间选择较新版本，阅读位置独立按更新时间合并；密码保存在 iOS 钥匙串。 |
| 诊断 | 从“我的”页面导出最近 7 天的应用日志；包含 EPUB 下载状态、TXT 导入阶段、解码字节数、分章数量与耗时、失败的系统错误域/代码。导出摘要会统计 TXT 导入、解码与分章诊断记录数。 |

EPUB 阅读器的容器解析、页面缓存、翻页界面和字体管理代码位于 [`iOSApp/EPUBReader/`](iOSApp/EPUBReader/)。排版依赖 [YueduCoreText 0.8.0](https://github.com/CHANG-JUI-LIN/YueduCoreText)。依赖说明见[阅读器依赖](iOSApp/EPUBReader/DEPENDENCIES.md)，当前限制见下文。

WebDAV 使用方法：在“我的 → WebDAV 同步”打开同步开关，并填入可写的 HTTPS WebDAV 文件夹地址、用户名和密码（或应用密码）。之后在“我的下载”点同步按钮开始；同步过程中再次点按钮可打开进度浮窗并取消任务。另一台设备配置相同地址并同步后，会恢复云端较新的书籍记录。网络小说按下载时间、文库书按导入时间逐本比较；阅读位置分别按更新时间合并，网络小说记录章节序号，EPUB 记录文件哈希对应的阅读比例。同步采用追加与恢复：本地删除不会删除云端副本，后续同步可能再次恢复该书。取消不会回滚已经传输或恢复的文件，远端目录清单在同步最后阶段写入。服务器会生成 `NoveliaSync/v1/`，其中的下载文件与书目未做端到端加密。

## 下载与运行

[下载最新 Release](https://github.com/Guanine000/novelia-swift/releases/latest) · [查看发行记录](https://github.com/Guanine000/novelia-swift/releases)

Release 附件是**未签名 IPA**，安装到常规真机前需要自行签名。要从源码运行，使用 Xcode 打开 `NoveliaIOS.xcodeproj`，选择 `Novelia` scheme 和 iPhone 模拟器或已配置签名的设备。依赖由 Swift Package Manager 解析，锁定版本见 `NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。


项目主要目录：`iOSApp/` 为 SwiftUI 应用与 EPUB 阅读器，`Sources/NoveliaIOSCore/` 为 API、模型、论坛 Markdown、TXT 分章与同步合并等不依赖界面的代码，`Tests/` 为单元测试与合成 EPUB 样例，`NoveliaIOS.xcodeproj/` 为 Xcode 工程。

单元测试在 iOS 模拟器上运行：`scripts/run_package_tests.sh [模拟器名称或 UDID]`。`scripts/scan_epub_layout.sh <书籍.epub>` 用阅读器默认设置排版一本本地 EPUB，报告两端对齐行的异常空隙和超出边距的行，书籍不会复制进仓库。

启动时可自动检查公开 GitHub 仓库的最新正式 Release，发现新版本后可跳转下载、取消或忽略该版本；可在“我的 → 版本”关闭自动检查。

论坛列表筛选与排序与网页端保持一致：小说讨论提供标签筛选，站务公告和意见反馈不提供标签筛选。

## 已知限制

- EPUB 翻页、目录、注脚、样式、字体导入与删除等交互仍需要在更多真机和真实书籍上验证；构建成功不等于所有 EPUB 都能正确排版。
- 复杂 CSS 受 YueduCoreText 当前支持范围限制。`text-shadow` 使用文字颜色近似；目录或书内链接落到目标章节首页，同章锚点不能精确定位。
- EPUB 全书进度按章节和章内页数估算；样式改变或跨设备恢复阅读位置时也按比例近似定位。EPUB 书签和书内搜索尚未实现。
- WebDAV 目前需在“我的下载”手动同步，要求 HTTPS 与可写的 WebDAV 文件夹。书籍冲突按网络小说下载时间或文库导入时间选择较新版本；删除不传播，云端书目会保留，并可能在之后的同步中恢复到本机。尚无后台自动同步。
- WebDAV 实现尚未用真实服务器及两台设备验证；不同服务端对条件写入与目录创建的支持可能有差异。
- 网络小说目前仅支持 EPUB 整本下载（原文、译文或双语）；TXT 通过本地文件导入阅读，不提供网络 TXT 下载。SRT 阅读和后台下载队列尚未实现。本地导入的 TXT 支持 UTF-8、带 BOM 的 UTF-16/32、GB18030/GBK、Big5 和 Shift_JIS 编码。TXT 分章按常见标题格式保守识别，特殊作品格式可能需要手动处理；可信章节少于 3 个时会退回全文阅读。

## 许可与第三方软件

App 在“我的 → 开源许可”提供第三方许可原文；仓库的[完整依赖清单](iOSApp/Resources/ThirdPartyLicenses/INDEX.md)列出 `Package.resolved` 中全部 3 个 Swift Package 的版本、来源及许可文件。IPA 随附这些原始许可文本、YueduCoreText 的 MPL-2.0 许可和包含 Unicode License v3 的 NOTICE。YueduCoreText 对应源码为[精确锁定的提交](https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe)，本项目没有修改该依赖的上游源码。用户自行导入的字体保存在本机 App 文档目录，不随本项目 IPA 分发；字体文件仍受其自身许可约束。

**TXT 分章参考：** [Qingdu Reader](https://github.com/zengchen666/qingdu-reader) 使用 Apache License 2.0。本项目仅参考其公开说明中的设计思路，分章识别器为独立 Swift 实现；没有复制、修改或随包分发 Qingdu Reader 的源代码、二进制或资源。Apache-2.0 原文见 [Qingdu Reader LICENSE](https://github.com/zengchen666/qingdu-reader/blob/main/LICENSE)。

最新 Release 附有本项目对应版本源码归档，以及 YueduCoreText 锁定提交的源码和许可材料。分发 IPA 时应同时提供同一版本的完整对应源码与第三方许可材料。构建流程使用 [`scripts/verify_third_party_notices.py`](scripts/verify_third_party_notices.py) 核对锁定依赖、许可清单和原始文件，并检查许可资源是否进入 IPA。发布前还需运行 `python3 scripts/verify_release_privacy.py <IPA路径>`，检查包内是否包含开发者主目录路径或常见凭据特征。

本仓库中由项目维护者拥有授权权利的 App 源代码和项目文档采用 **GNU GPL-3.0-only**（SPDX：`GPL-3.0-only`），完整条款见根目录 [LICENSE](LICENSE)。本 iOS 项目是参考 [GPL-3.0-only 安卓客户端](https://github.com/nobYoQ/novelia) 制作的 Swift 移植版本，包含平台适配和后续修改；上游版权声明 `Copyright (C) 2026 Novelia Android contributors.` 予以保留。本 iOS 移植及新增部分版权声明为 `Copyright (C) 2026 Novelia iOS contributors.`，修改版本日期为 2026-10-09。

第三方组件、YueduCoreText、用户导入字体、Novelia 网站内容、小说与用户内容仍分别适用其自身许可证或权利声明，不被本仓库的 GPL 声明替代或重新授权。完整第三方清单、许可文本和 YueduCoreText 对应源码见上方清单及最新 Release 附件。默认书本图标由维护者使用 GPT 生成并提供，随本项目源码和 IPA 分发；其他非代码资源仍以其各自权利状态为准。

## 反馈

普通问题请通过 [Issues](https://github.com/Guanine000/novelia-swift/issues) 提交。公开反馈前请移除账号、令牌、WebDAV 凭据、私人书籍和个人信息。安全漏洞请通过[私密安全报告](https://github.com/Guanine000/novelia-swift/security/advisories/new)提交。

## 本机构建与分发

无需 GitHub Actions 或处理账单即可在 macOS／Xcode 本机构建。先按 VERSIONING.md 设置 Debug／Release 一致的版本与新构建号，再运行：

```sh
python3 -I scripts/build_local_release.py --simulator 'iPhone 18 Pro Max'
```

未提交的开发测试使用 `--allow-dirty`，例如：

```sh
python3 -I scripts/build_local_release.py --allow-dirty --simulator DFDA05C7-BA73-43B8-B711-511113CA3BCB
```

脚本运行 Swift 包逻辑／排版测试（不运行模拟器 UI 测试）、四项离线回归、Release 真机构建、原始依赖许可与包内资源核对、IPA 隐私检查，生成未签名 IPA、完整对应源码、锁定依赖完整源码／许可、BUILD.json 和 SHA256SUMS。Xcode 派生数据默认放在系统临时目录下的新目录（成功后删除，失败时保留供排查）；Release 二进制会记录目标文件路径，`--derived-data` 不得位于用户主目录下，否则 IPA 隐私检查会失败。产物位于忽略的 `build/local-releases/<版本>-<构建号>/`；只有出现 SUCCESS 才可分发。输出目录已存在时拒绝覆盖，源码在构建期间变化也会失败。脚本不修改版本、不提交、不推送、不发布。

分发时一并提供 IPA、source.tar.gz、dependencies.tar.gz、BUILD.json 与 SHA256SUMS；未签名 IPA 需接收者自行重签。目录中的构建／测试日志仅供本机排障，可能含开发环境路径，不是应用的隐私过滤日志，不作为发布附件。

ReaderSettings 共用字號、主题和背景入口；EPUB 特有排版选项与既有进度格式保留。在线／TXT 的分页迁移评估见 [READER_PAGINATION.md](READER_PAGINATION.md)。
