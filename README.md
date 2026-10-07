# Novelia iOS 移植

这是一个独立的 SwiftUI iOS 项目，移植对照对象是第三方原生 Android 客户端 [nobYoQ/novelia](https://github.com/nobYoQ/novelia)。该 Android 客户端基于 [AutoNovel 网页版及服务端](https://github.com/auto-novel/auto-novel) 提供的服务开发。本 README 的功能差距清单以 Android 客户端为准，AutoNovel 是其上游网站/API 服务来源。**本 iOS 项目与这两个上游仓库分离，不会修改它们。**当前版本包含基础发现、在线阅读、账号认证、站内热度榜、阅读外观、网页评论区和简洁应用图标，但尚未达到 Android 客户端的功能完整度。

## 版本状态

- 最新已发布版本：**v0.3.0**（2026-10-07）。当前工作区包含尚未发布的文库功能开发。
- [查看 GitHub Release](https://github.com/Guanine000/novelia-ios-port/releases/tag/v0.3.0)，可下载 [未签名 IPA](https://github.com/Guanine000/novelia-ios-port/releases/download/v0.3.0/Novelia-unsigned.ipa)。
- 本版本新增 Novelia 网页评论区和简洁书本应用图标；排行榜仅提供站内点击热度榜，阅读器外观可选浅色、深色或跟随系统。

## 当前已实现

- SwiftUI 主入口：书架、网络小说发现、文库、我的；网络小说和文库各自使用独立搜索与收藏数据。
- 使用简洁的打开书本图案作为 iOS 主屏幕应用图标。
- 发现页调用 Novelia 公开 API 搜索在线作品，并在滚动到结果底部时自动分页加载。
- 发现页提供 Novelia 站内点击热度排行榜，支持分页浏览并可进入作品详情。
- 作品详情页标签可点击并精确筛选包含该标签的作品，标签结果页支持继续分页。
- 读取在线作品详情、章节目录和章节正文。
- 在线小说详情显示有道、GPT、Sakura 各自已翻译章节数；阅读设置可切换译源，译文和双语模式均按所选译源逐段显示。
- 在线小说详情显示原站提供的作品字数。
- 阅读页可通过章节目录跳转；网页历史作品可打开作品详情或继续阅读，阅读页使用常规导航页面展示。
- 基础章节阅读，支持原文、译文、逐段对照的双语显示，以及上一章/下一章。
- 阅读界面可切换浅色、深色或跟随系统；调整阅读字号；本地保存章节级阅读进度和章节书签。
- 在作品详情中选择网页端收藏夹收藏/取消收藏；书架登录后读取 Novelia 账号的云端收藏，并按账号缓存供离线查看。
- 作品详情可进入 Novelia 网页端评论区，分页查看评论和回复；登录后可发表评论和回复，内容同步到网页端。
- 首页横向展示少量最近阅读和网页收藏，均可进入完整列表；阅读历史列表分页加载，滑到底部会自动读取下一页。作品详情页提供续读入口，并优先使用云端最近章节位置。
- 小说账号统一认证流程：通过 WKWebView 登录，调用 refresh 接口获取应用令牌，并将令牌保存在 iOS Keychain。
- 文库入口调用 Novelia 文库搜索和详情接口，独立读取、添加及取消账号云端文库收藏。
- 文库作品详情显示分卷及百度、有道、GPT、Sakura 翻译可用数量；可下载译文 EPUB 或两种段落顺序的双语 EPUB。
- 本地 EPUB 书架支持从 Novelia 下载后阅读、从“文件”导入，以及通过系统分享导出；使用 Readium Swift Toolkit 解析和呈现 EPUB，提供目录跳转并保存本地阅读位置。
- 最低部署版本为 iOS 17。

> 文库收藏同步 Novelia 云端文库收藏夹，与网络小说收藏分开。上游下载接口拒绝单独生成日文原文 EPUB，因此当前只有译文和双语下载；原文单独下载需上游开放相应能力。
> 书架首页当前展示 Novelia 账号的网络小说收藏；本地收藏夹和云端书架的复杂管理尚未实现。

## 尚未实现

### 书架与账号

- 书架分组与整理、置顶、阅读状态、批量操作和本地阅读历史管理。
- 云端书架文件夹管理、云端阅读进度写入，以及本地阅读进度与网页端双向同步。
- 小说令牌自动续期、API 遇到 401 后恢复会话；独立论坛账号与会话。

### 发现与作品详情

- 书源/镜像切换。
- 标签库、标签翻译与分类管理、字数筛选、高级搜索表达式、屏蔽和保存搜索；作品详情里的标签精确搜索已支持。
- 分享链接识别与站内链接跳转。
- 作品资料编辑、文库元数据编辑、分卷上传与管理。

### 阅读器

- 滚动/分页切换、电子纸模式、行距和单本作品的独立设置。
- 更多译文排列与简繁显示选项。
- 精确到段落的阅读位置、章内/全书搜索、插图查看。
- 摘录、笔记、书签管理页和系统语音朗读。

### 文件与离线

- EPUB 的高级阅读偏好、书签管理页和批量文件管理。
- TXT、SRT 导入和本地阅读；章节缓存/预读、离线下载队列、备份恢复和文件转换工具。

### 社区、同步与维护

- 论坛内容流、帖子、评论编辑/删除、Markdown 编辑器、草稿和社区权限功能。
- WebDAV 多设备同步、离线写入队列与冲突处理。
- ECH 网络传输、书源线路配置、网络日志与诊断。
- 应用更新检查与通知，以及覆盖上述功能的自动化和设备测试。

## 在 Xcode 中运行

1. 用 Xcode 打开 `NoveliaIOS.xcodeproj`。
2. 选择 `Novelia` scheme 和 iPhone 模拟器。
3. 点击 Run，或按 **⌘R**。

项目最低部署版本是 iOS 17。Xcode 工程使用 Swift Package Manager 引入 Readium Swift Toolkit。`Package.swift` 单独提供平台无关的 `NoveliaIOSCore` 模型和样例数据。最新已发布的 v0.3.0 已通过 iOS Simulator Debug 构建和 GitHub Actions 设备版构建；本地文库开发版本已通过 iOS Simulator Debug 构建，文库在线接口和真实 EPUB 文件仍待模拟器端到端验证。

## 使用 GitHub Actions 构建 IPA

推送到 `main` 后，GitHub Actions 会自动构建 iOS 设备版并发布名为 `Novelia-unsigned-ipa` 的工件；也可以在仓库的 **Actions** 页面手动运行 **Build iOS IPA**。完成后从对应运行记录的 **Artifacts** 下载 `Novelia-unsigned.ipa`。

此工作流产出未签名 IPA。当前 v0.3.0 的 IPA 已附在 GitHub Release 中。未签名 IPA 不能直接用于常规真机安装或发布到 App Store；这仍需要 Apple 开发者签名证书及匹配的 provisioning profile，并在工作流中配置签名。

## 项目结构

- `iOSApp/`：SwiftUI 页面、在线阅读器、Readium EPUB 阅读器和账号认证。
- `Sources/NoveliaIOSCore/`：网络小说与文库模型、样例数据、Novelia API 客户端和 Keychain 令牌存储。
- `NoveliaIOS.xcodeproj/`：Xcode 工程。

## 许可证与移植边界

Android 对照项目 `nobYoQ/novelia` 标注为 GPL-3.0-only；AutoNovel 上游仓库也提供其自己的许可证声明。当前 iOS 移植是独立 Swift 实现；如后续直接复用任一上游仓库的代码或第三方资源用于分发，请分别核对对应许可证、版权声明和依赖条款。
