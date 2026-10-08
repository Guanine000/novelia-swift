# Novelia iOS

Novelia iOS 是使用 SwiftUI 编写的 iPhone 客户端，连接 Novelia 网站浏览网络小说与文库、阅读章节、管理收藏和下载 EPUB。项目还提供基于 YueduCoreText 的原生 EPUB 分页阅读器。最低系统版本为 **iOS 17**。

本项目参考 [nobYoQ/novelia](https://github.com/nobYoQ/novelia) 的产品功能；Novelia 网站与 API 来自 [AutoNovel](https://github.com/auto-novel/auto-novel)。这些项目及网站内容分别适用各自的权利与许可条件。

## 功能

| 模块 | 当前能力 |
| --- | --- |
| 发现与作品 | 搜索网络小说和文库、筛选标签、查看站内热度榜与作品详情。 |
| 账号与书架 | 使用 Novelia 统一认证；读取网络小说和文库收藏、最近阅读与阅读历史。 |
| 在线章节 | 原文、译文或逐段双语阅读；章节目录、阅读进度、书签、字号和深浅色设置。 |
| 评论 | 查看网络小说与文库的网页评论和回复；登录后发表与回复。 |
| EPUB 下载 | 使用 Novelia 官网整本接口下载网络小说 EPUB；下载文库译文或双语 EPUB；在“我的下载”中导出或删除。 |
| EPUB 阅读 | 从“我的下载”打开 EPUB，或通过“文件”导入；解析 EPUB 2 NCX / EPUB 3 nav、图片与部分 ruby；左右相接的跟手平移翻页、目录跳转、注脚弹层、书内链接、可拖动进度条。 |
| 阅读样式 | 设置字号、字体、行间距、段落间距、首行缩进和四边边距；恢复默认；从“文件”导入 TTF/OTF/TTC，并在管理页选用或删除。 |
| 诊断 | 从“我的”页面导出应用日志；阅读器对部分资源和排版失败给出可读错误。 |

EPUB 阅读器的容器解析、页面缓存、翻页界面和字体管理代码位于 [`iOSApp/EPUBPrototype/`](iOSApp/EPUBPrototype/)。排版依赖 [YueduCoreText 0.8.0](https://github.com/CHANG-JUI-LIN/YueduCoreText)。[阅读器报告](EPUB_READER_REPORT.md) 记录了实现过程、真实书样本和已知限制。

## 下载与运行

[下载 v0.5.0 Release](https://github.com/Guanine000/novelia-ios-port/releases/tag/v0.5.0) · [查看发行记录](https://github.com/Guanine000/novelia-ios-port/releases)

Release 附件是**未签名 IPA**，安装到常规真机前需要自行签名。要从源码运行，使用 Xcode 打开 `NoveliaIOS.xcodeproj`，选择 `Novelia` scheme 和 iPhone 模拟器或已配置签名的设备。依赖由 Swift Package Manager 解析，锁定版本见 `NoveliaIOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。

仓库保持私密，当前只保留 v0.5.0 的 GitHub Release；旧版本 Git 标签仍保留供历史追溯。若已下载较早的 IPA，请改用 v0.5.0。已经转交出去的旧文件不会因 Release 删除而消失。

项目主要目录：`iOSApp/` 为 SwiftUI 应用与 EPUB 阅读器，`Sources/NoveliaIOSCore/` 为 API、模型和存储代码，`NoveliaIOS.xcodeproj/` 为 Xcode 工程。

## 已知限制

- EPUB 翻页、目录、注脚、样式、字体导入与删除等交互仍需要在更多真机和真实书籍上验证；构建成功不等于所有 EPUB 都能正确排版。
- 复杂 CSS 受 YueduCoreText 当前支持范围限制。`text-shadow` 使用文字颜色近似；目录或书内链接落到目标章节首页，同章锚点不能精确定位。
- EPUB 全书进度是按章节和章内页数估算；样式改变后的阅读位置也按页数比例近似恢复。EPUB 阅读位置跨启动持久化、EPUB 书签和书内搜索尚未实现。
- TXT / SRT 阅读、WebDAV 同步、后台下载队列和备份恢复尚未实现。

## 许可与第三方软件

App 在“我的 → 开源许可”提供第三方许可原文；仓库的[完整依赖清单](iOSApp/Resources/ThirdPartyLicenses/INDEX.md)列出 `Package.resolved` 中全部 10 个 Swift Package 的版本、来源及许可文件。IPA 随附这些原始许可文本、YueduCoreText 的 MPL-2.0 许可和包含 Unicode License v3 的 NOTICE。YueduCoreText 对应源码为[精确锁定的提交](https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe)，本项目没有修改该依赖的上游源码。用户自行导入的字体保存在本机 App 文档目录，不随本项目 IPA 分发；字体文件仍受其自身许可约束。

v0.5.0 Release 还附有该精确提交的 [`YueduCoreText-0.8.0-source-783ce903.zip`](https://github.com/Guanine000/novelia-ios-port/releases/download/v0.5.0/YueduCoreText-0.8.0-source-783ce903.zip)，包含上游 LICENSE 与 NOTICE，供 IPA 接收者取得对应 MPL 覆盖源码。构建流程使用 [`scripts/verify_third_party_notices.py`](scripts/verify_third_party_notices.py) 核对锁定依赖、许可清单和原始文件，并检查许可资源是否进入 IPA。

本仓库目前**没有声明覆盖自有代码的统一开源许可证**，且保持私密。维护者确认 App 图标由本人制作或使用 AI 生成，未直接取自 Android 对照项目或 Yuedu-reader；该说明不改变第三方代码和素材各自的许可。第三方软件许可不自动授权使用本项目其他代码、图标、小说内容或 Novelia 服务数据。发行包对第三方依赖的告知以随包的原始许可和 NOTICE 为准。
