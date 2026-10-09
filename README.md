# Novelia iOS

本项目为[轻小说机翻机器人](https://n.novelia.cc/)的第三方客户端。

Novelia iOS 是使用 SwiftUI 编写的 iPhone 客户端，连接 Novelia 网站浏览网络小说与文库、阅读章节、管理收藏和下载 EPUB，并支持导入 TXT / EPUB 文件。项目还提供基于 YueduCoreText 的原生 EPUB 分页阅读器。最低系统版本为 **iOS 17**。

本项目参考 [nobYoQ/novelia](https://github.com/nobYoQ/novelia) 的产品功能；Novelia 网站与 API 来自 [AutoNovel](https://github.com/auto-novel/auto-novel)。这些项目及网站内容分别适用各自的权利与许可条件。

## 功能

| 模块 | 当前能力 |
| --- | --- |
| 发现与作品 | 搜索网络小说和文库、筛选标签、查看站内热度榜与作品详情。 |
| 账号与书架 | 使用 Novelia 统一认证；读取网络小说和文库收藏、最近阅读与阅读历史。 |
| 论坛 | 浏览论坛分类与帖子，按活跃度、发布时间、浏览量或评论数排序；搜索帖子、查看详情与回复；论坛账号可单独登录、发帖、评论、回复和收藏。论坛登录会话与 Novelia 小说账号分开保存。 |
| 在线章节 | 原文、译文或逐段双语阅读；章节目录、阅读进度、书签、字号和深浅色设置；正文中的 HTTP/HTTPS 链接以带下划线的链接样式呈现，可点按打开。 |
| 评论 | 查看网络小说与文库的网页评论和回复；登录后发表与回复。 |
| EPUB 下载 | 使用 Novelia 官网整本接口下载网络小说 EPUB；下载文库译文或双语 EPUB；在“我的下载”中导出或删除。 |
| 本地书籍导入 | 在“我的下载”中从“文件”多选导入 EPUB 和 TXT；浮窗显示批量处理进度，完成后加入本地书籍列表，可阅读、导出或删除。 |
| EPUB 阅读 | 从“我的下载”打开 EPUB；解析 EPUB 2 NCX / EPUB 3 nav、图片与部分 ruby；左右相接的跟手平移翻页、单页/双页模式、多字拖选与复制/查询/网页搜索/分享、目录跳转、注脚弹层、书内链接、可拖动进度条；目录提供可折叠、可复制的解析与排版诊断。 |
| TXT 导入与阅读 | 从“文件”多选导入 TXT；本地阅读支持常见中英文标题分章、卷标题、章节目录、字号与主题设置。“我的 → 阅读体验 → TXT 分章规则”可启停内置规则，并添加、编辑或删除自定义整行正则。分章规则设计参考 [Qingdu Reader](https://github.com/zengchen666/qingdu-reader)（Apache-2.0），本项目为独立 Swift 实现。 |
| 阅读样式 | 设置字号、字体、行间距、段落间距、首行缩进和四边边距；恢复默认；从“文件”导入 TTF/OTF/TTC，并在管理页选用或删除。 |
| WebDAV 同步 | 在“我的 → WebDAV 同步”启用并配置 HTTPS WebDAV；在“我的下载”点同步开始，同步中再次点按可查看进度或取消；按书籍的下载/导入时间选择较新版本，阅读位置独立按更新时间合并；密码保存在 iOS 钥匙串。 |
| 诊断 | 从“我的”页面导出最近 7 天的应用日志；包含 EPUB 下载状态、TXT 导入阶段、解码字节数、分章数量与耗时、失败的系统错误域/代码。导出摘要会统计 TXT 导入、解码与分章诊断记录数。 |

EPUB 阅读器的容器解析、页面缓存、翻页界面和字体管理代码位于 [`iOSApp/EPUBPrototype/`](iOSApp/EPUBPrototype/)。排版依赖 [YueduCoreText 0.8.0](https://github.com/CHANG-JUI-LIN/YueduCoreText)。依赖说明见[阅读器依赖](iOSApp/EPUBPrototype/DEPENDENCIES.md)，当前限制见下文。

WebDAV 使用方法：在“我的 → WebDAV 同步”打开同步开关，并填入可写的 HTTPS WebDAV 文件夹地址、用户名和密码（或应用密码）。之后在“我的下载”点同步按钮开始；同步过程中再次点按钮可打开进度浮窗并取消任务。另一台设备配置相同地址并同步后，会恢复云端较新的书籍记录。网络小说按下载时间、文库书按导入时间逐本比较；阅读位置分别按更新时间合并，网络小说记录章节序号，EPUB 记录文件哈希对应的阅读比例。同步采用追加与恢复：本地删除不会删除云端副本，后续同步可能再次恢复该书。取消不会回滚已经传输或恢复的文件，远端目录清单在同步最后阶段写入。服务器会生成 `NoveliaSync/v1/`，其中的下载文件与书目未做端到端加密。

## 下载与运行

[下载最新 Release](https://github.com/Guanine000/novelia-swift/releases/latest) · [查看发行记录](https://github.com/Guanine000/novelia-swift/releases)

Release 附件是**未签名 IPA**，安装到常规真机前需要自行签名。要从源码运行，使用 Xcode 打开 `NoveliaIOS.xcodeproj`，选择 `Novelia` scheme 和 iPhone 模拟器或已配置签名的设备。依赖由 Swift Package Manager 解析，锁定版本见 `NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。


项目主要目录：`iOSApp/` 为 SwiftUI 应用与 EPUB 阅读器，`Sources/NoveliaIOSCore/` 为 API、模型和存储代码，`NoveliaIOS.xcodeproj/` 为 Xcode 工程。

## 已知限制

- EPUB 翻页、目录、注脚、样式、字体导入与删除等交互仍需要在更多真机和真实书籍上验证；构建成功不等于所有 EPUB 都能正确排版。
- 复杂 CSS 受 YueduCoreText 当前支持范围限制。`text-shadow` 使用文字颜色近似；目录或书内链接落到目标章节首页，同章锚点不能精确定位。
- EPUB 全书进度按章节和章内页数估算；样式改变或跨设备恢复阅读位置时也按比例近似定位。EPUB 书签和书内搜索尚未实现。
- WebDAV 目前需在“我的下载”手动同步，要求 HTTPS 与可写的 WebDAV 文件夹。书籍冲突按网络小说下载时间或文库导入时间选择较新版本；删除不传播，云端书目会保留，并可能在之后的同步中恢复到本机。尚无后台自动同步。
- WebDAV 实现尚未用真实服务器及两台设备验证；不同服务端对条件写入与目录创建的支持可能有差异。
- 网络小说目前仅支持 EPUB 整本下载（原文、译文或双语）；TXT 通过本地文件导入阅读，不提供网络 TXT 下载。SRT 阅读和后台下载队列尚未实现。本地导入的 TXT 支持 UTF-8、带 BOM 的 UTF-16/32、GB18030/GBK、Big5 和 Shift_JIS 编码。TXT 分章按常见标题格式保守识别，特殊作品格式可能需要手动处理；可信章节少于 3 个时会退回全文阅读。

## 许可与第三方软件

App 在“我的 → 开源许可”提供第三方许可原文；仓库的[完整依赖清单](iOSApp/Resources/ThirdPartyLicenses/INDEX.md)列出 `Package.resolved` 中全部 10 个 Swift Package 的版本、来源及许可文件。IPA 随附这些原始许可文本、YueduCoreText 的 MPL-2.0 许可和包含 Unicode License v3 的 NOTICE。YueduCoreText 对应源码为[精确锁定的提交](https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe)，本项目没有修改该依赖的上游源码。用户自行导入的字体保存在本机 App 文档目录，不随本项目 IPA 分发；字体文件仍受其自身许可约束。

**TXT 分章参考：** [Qingdu Reader](https://github.com/zengchen666/qingdu-reader) 使用 Apache License 2.0。本项目仅参考其公开说明中的设计思路，分章识别器为独立 Swift 实现；没有复制、修改或随包分发 Qingdu Reader 的源代码、二进制或资源。Apache-2.0 原文见 [Qingdu Reader LICENSE](https://github.com/zengchen666/qingdu-reader/blob/main/LICENSE)。

最新 Release 附有本项目对应版本源码归档，以及 YueduCoreText 锁定提交的源码和许可材料。分发 IPA 时应同时提供同一版本的完整对应源码与第三方许可材料。构建流程使用 [`scripts/verify_third_party_notices.py`](scripts/verify_third_party_notices.py) 核对锁定依赖、许可清单和原始文件，并检查许可资源是否进入 IPA。

本仓库中由项目维护者拥有授权权利的 App 源代码和项目文档采用 **GNU GPL-3.0-only**（SPDX：`GPL-3.0-only`），完整条款见根目录 [LICENSE](LICENSE)。本 iOS 项目是参考 [GPL-3.0-only 安卓客户端](https://github.com/nobYoQ/novelia) 制作的 Swift 移植版本，包含平台适配和后续修改；上游版权声明 `Copyright (C) 2026 Novelia Android contributors.` 予以保留。本 iOS 移植及新增部分版权声明为 `Copyright (C) 2026 Novelia iOS contributors.`，修改版本日期为 2026-10-09。

第三方组件、YueduCoreText、用户导入字体、Novelia 网站内容、小说与用户内容仍分别适用其自身许可证或权利声明，不被本仓库的 GPL 声明替代或重新授权。完整第三方清单、许可文本和 YueduCoreText 对应源码见上方清单及最新 Release 附件。默认书本图标由维护者使用 GPT 生成并提供，随本项目源码和 IPA 分发；其他非代码资源仍以其各自权利状态为准。

## 反馈

普通问题请通过 [Issues](https://github.com/Guanine000/novelia-swift/issues) 提交。公开反馈前请移除账号、令牌、WebDAV 凭据、私人书籍和个人信息。安全漏洞请通过[私密安全报告](https://github.com/Guanine000/novelia-swift/security/advisories/new)提交。
