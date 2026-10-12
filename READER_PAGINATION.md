# 在线小说与 TXT 共用 YueduCoreText 分页的评估

评估日期：2026-10-12。基于当前工作区的 EPUBReader、ReaderView、TXTReaderView；本轮完成 ReaderSettings 与本地构建流程，尚未切换在线／TXT 阅读模式。

## 本轮共用设置

三套阅读器使用 ReaderSettings 的字號与 light/dark/system 外观；背景继续由同一 ReaderBackgroundStore 管理，EPUB 的颜色与图片经共享入口解析。统一字號范围 12–36，EPUB 独有的字体、行段间距、缩进、边距与双页选项仍在 EPUBReaderStyle。

兼容规则：不改 readerFontSize、readerAppearance、epubPrototype.readerStyle.v1、readerBackground.* 等既有键。第一次读取优先现有 readerFontSize；没有它时采用旧 EPUB 样式字號，再回退 20。仅读取不迁移写盘；用户调整字號后写回原全局键，并仅更新旧 EPUB 样式中的 fontSize 字段。若此前两处字號不同，现有全局字號成为共同值。动画／排版中的共享变化待结束后统一重排，保留现有章节偏移定位。

阅读进度共用 ReaderSettings 的访问入口，但不统一成一个未经迁移的存储格式：在线小说继续 progress.<id>、progressTime.<id> 与 readingPositions.v1 的章节索引；EPUB 继续 spine、UTF-16 偏移及旧版 fraction。TXT 当前只有会话内章节位置，没有持久化进度，本轮未悄悄添加新的同步协议。

## 结论与建议

技术上可行，推荐先迁移 TXT，再迁移在线小说；应复用 EPUB 的页面标识、位图缓存、翻页手势与选字能力。共用设置完成后仍不足以直接把滚动视图替换为 EPUBReaderView：目前 EPUBPageBook.layoutChapter 接收 EPUBContainer，依赖 spine、章节 XHTML、CSS、图片、链接锚点和完整章节状态。需要先抽出章节内容接口，而不是将每次下载结果临时压成一本 EPUB。

不升级或修改 YueduCoreText 0.8.0 即可使用现有公开 BrowserLayoutSession API。保留既有对齐权宜修法及 MPL-2.0／MIT 许可材料。

## 所需接口和迁移顺序

1. 新建章节来源协议，提供稳定书籍标识、章节标识、目录、XHTML、资源和内容版本。EPUBContainer 作为现有实现接入；TXT 来源直接读取 TXTChapterParser 的结果。PageBook 与阅读模型只依赖章节来源，仍以 generation × chapter × page 标识位图。
2. TXT 正文转成经过 XML 转义的段落 XHTML，不将用户文本直接拼入标签或 CSS。每段携带稳定源文本偏移，选字与进度均映射回原 TXT 字符位置，避免把 XHTML 标签长度当成原文位置。先增加本地章内偏移恢复，再决定是否把 TXT 进度加入 WebDAV；须有旧版与新字段兼容测试。
3. 在线来源按当前翻译源和原文／译文／双语模式生成段落，保留现有段落顺序、颜色和缺译提示；缓存键纳入章节、译源、显示模式及内容版本。保留请求取消、401续期、相邻章预取和错误重试，不能让翻页阻塞主线程。
4. 在线进度继续向服务端上报章节；本地新增章内位置时保留旧章索引与同步时间。模式变化用段落标识和段内偏移恢复，不能把某个译文的字符偏移直接套用到原文。书签仍指向原章节 ID。
5. TXT 分页通过后再接在线模式。滚动与分页应在过渡阶段都可用，待用户真机确认后决定默认模式；不得删除现有滚动实现来迫使迁移。

## 必须保留与验收

- TXT：既有编码、分章规则、卷标题、全文回退、长章分块性能；特殊字符与 emoji／组合字符的源偏移正确；改字號和重开定位。
- 在线：原文／译文／双语、译源切换、缺译状态、目录自动定位、书签、阅读历史与服务端章节上报；快速切章时取消旧请求，网络失败后可恢复。
- 三者：相同的翻页手势与预览／落页、跨章、双页、旋转、选字、背景和内存窗口。不得因连续预取无限累积位图。
- 先做包测试与真机构建；模拟器 UI 测试仍按用户要求暂停。排版字数测试不能替代真机手势／选字与网络验收。

这项迁移将新增可独立使用的在线／TXT 分页阅读能力，应按 VERSIONING.md 使用 minor 版本，并递增构建号；本轮共用设置和本地脚本仍作为 0.11.3 的整理与兼容改动。
