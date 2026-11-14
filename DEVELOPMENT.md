# Novelia 开发文档

本文件介绍 Novelia 的项目结构、运行方式、主要功能实现和开发规则，供开发者与 Agent 理解和维护代码。架构、接口、数据格式或构建方式改变时，应同步更新相关章节。具体行为以实现和测试为准。用户可见的功能与行为见 [功能说明](docs/FEATURES.md) 和 [WebDAV 同步](docs/WEBDAV.md)，发布流程见 [本机构建与分发](docs/BUILD.md)。

## 目录

- [项目概览](#项目概览)
- [开始开发](#开始开发)
- [目录与依赖方向](#目录与依赖方向)
- [启动、导航和状态生命周期](#启动导航和状态生命周期)
- [功能实现地图](#功能实现地图)
- [API、数据模型与认证](#api数据模型与认证)
- [本地状态与跨功能连接](#本地状态与跨功能连接)
- [阅读器实现](#阅读器实现)
- [网络小说 EPUB 章节同步与更新](#网络小说-epub-章节同步与更新)
  - [手动更新事务](#手动更新事务)
  - [ID 阅读状态与同步](#id-阅读状态与同步)
  - [更新时的本地文件对应](#更新时的本地文件对应)
  - [管理入口与核对性能](#管理入口与核对性能)
  - [旧下载配置确认](#旧下载配置确认)
- [书库、文件与统计实现](#书库文件与统计实现)
- [WebDAV 同步实现](#webdav-同步实现)
- [网络、缓存与诊断约定](#网络缓存与诊断约定)
- [新增、修改与删除功能](#新增修改与删除功能)
- [数据兼容](#数据兼容)
- [文件注册与构建配置](#文件注册与构建配置)
- [构建与验证](#构建与验证)
- [iOS 15 兼容规则](#ios-15-兼容规则)
- [性能基线](#性能基线)
- [架构演进](#架构演进)
- [文档维护](#文档维护)
- [交付前检查](#交付前检查)
- [许可](#许可)

## 项目概览

Novelia 是第三方小说客户端，使用 Swift、SwiftUI 和 UIKit。主目标 `Novelia` 面向 iOS 17 及以上，默认使用 YueduCoreText 分页。另一个 App 目标 `NoveliaLegacy`（bundle id `cc.novelia.ios.port.ios15`）面向 iOS 15，不链接 YueduCoreText 与 CLibMobi，分页固定为 Readium。主要能力包括网络小说和文库发现、收藏与历史、论坛、本地 TXT/EPUB 书库、在线阅读、EPUB 下载、阅读统计和 WebDAV 同步（手动或自动）。

界面使用 SwiftUI，阅读器按引擎需要结合原生视图和 WebKit。可观察状态通常由 `@MainActor` Store 管理；远端操作使用异步服务接口；Core 保存业务模型、算法和存储逻辑。项目没有统一采用单一大型 ViewModel，每个功能应沿用适合其职责的现有实现。

API 实现在开发时通过组装替换。项目采用服务协议、统一组装、功能目录和跨功能适配；没有用户书源系统或动态插件系统。

Xcode App 当前直接编译 App 与 Core 源文件，功能目录并不是独立编译模块。两个 App 目标编译同一批源文件，差别只在部署版本、编译条件 `NOVELIA_READIUM_ONLY`、被排除的原生分页／Kindle 源文件和链接的包。Swift Package 为 Core 与 EPUB 提供测试目标，平台仍是 iOS 17，因为测试里的 `NoveliaEPUB` 依赖上游 YueduCoreText、`NoveliaKindle` 依赖 CLibMobi；不要假设编译器已经阻止所有跨目录依赖。

## 开始开发

开发环境：macOS 上的 Xcode（当前使用 Xcode 27.2）、iOS 17 模拟器（主目标）或 iOS 15 模拟器（`NoveliaLegacy`），以及用于离线回归与发布脚本的 Python 3。App 编译与测试命令见[构建与验证](#构建与验证)。云端环境没有 Xcode，iOS 15 目标需要在 Mac 上编译确认。

每次任务开始：

1. 阅读根目录 `AGENTS.md` 和本文件，查看工作区已有改动。
2. 确定涉及的功能、协议、组装入口和持久化数据，读取对应实现与测试。
3. 选择最小合理改动范围；明确是否触及认证、存储格式、阅读引擎或同步合并规则。
4. 使用已有接口和实例完成改动，按“构建与验证”选择检查；发现边界不足时按“架构演进”调整。

阅读代码时从所属功能入口、Store、依赖协议和具体实现顺序定位。当前文件位置以代码和 `scripts/source_layout.json` 为准，不根据旧文件名猜测根目录路径。

## 目录与依赖方向

| 位置 | 职责 | 避免放入 |
|---|---|---|
| `iOSApp/App/NoveliaApp.swift` | 启动、Root、导航与环境注入 | HTTP 编码、业务算法和大型功能实现 |
| `iOSApp/App/AppServices.swift` | API、本地服务与账号实例组装 | 页面状态和具体网络业务 |
| `iOSApp/App/Integrations/` | 连接不同功能的具体实例、事件和适配 | 功能内部逻辑 |
| `iOSApp/App/Diagnostics/` | Debug 独立验证组装 | 正式功能或生产数据回退 |
| `iOSApp/Features/<功能>/` | 页面、可观察 Store、平台与界面适配 | 具体 API 客户端和其他功能的内部状态查找 |
| `iOSApp/Shared/` | 已有真实复用需求的 UI | 无归属的业务逻辑 |
| `Sources/NoveliaIOSCore/Domain/` | 业务模型、API 与本地能力协议 | 具体网络实现、SwiftUI、App 组装 |
| `Sources/NoveliaIOSCore/Infrastructure/API/` | 请求、响应映射、地址配置、当前服务工厂 | 页面、导航和界面状态 |
| `Sources/NoveliaIOSCore/Features/<功能>/` | 可测试的功能逻辑、存储和算法 | 依赖具体 App 页面 |
| `Sources/NoveliaIOSCore/Support/` | 通用工具和现有共享约定 | 为省事放入的跨功能业务 |

App 功能目录包括 Account、Discover、Library、Wenku、Downloads、Reader、Community、Statistics、Sync、Settings。阅读引擎实现在 `Features/Reader/EPUBReader/`。新增功能优先放在相应目录；独立功能才增加目录。

约定依赖方向：

```text
App 组装 → 页面 / Store / 本地实现 / API 实现
页面 / Store / 阅读缓存 → Domain 服务协议与模型
API 实现 → Domain 协议与模型
跨功能连接 → App/Integrations → 各功能公开能力
Core 功能逻辑 → Domain 与通用 Support
```

已有某些界面入口和导航会跨功能引用；本约定不要求为导航全部建立协议。需要共享业务能力时，提供明确接口或 App 适配，避免读取另一个功能 Store 的内部字段、全局实例或私有文件格式。

界面颜色、圆角与常用字号统一使用 `NoveliaStyle`（App 层定义）：颜色为 `ink`/`muted`/`paper`/`card`/`brandGreen` 加语义化的 `danger`/`warning`，圆角三档 `radiusSmall`/`Medium`/`Large`（8/12/16），字号档 `fontMicro`/`Caption`/`Footnote`/`Body`（10/11/12/13，名称只表示档位）。`paper`/`card` 的浅色值来自 `AppPaperStyle` 预设（“我的 → 界面 → 界面底色”，动态色提供器读取 `appPaperStyle`，根视图持有对应 `@AppStorage` 保证换档时全树重渲染）；深色模式纸面/卡片固定，不随预设变化。界面层不再新增硬编码错误色或这三档之外的圆角；既有孤值（7、13–15、17–24 圆角与带 `weight`/`design` 的字号组合）保持原样，逐处确认归属后再收敛，不做盲改。

## 启动、导航和状态生命周期

`NoveliaApp` 是 `@main` 入口，用 `@StateObject` 持有 `AppServices`。正常启动通过 `AppServices.novelia(configuration:)` 创建配置、账号与服务集合，再交给 `RootView`。Debug 启动可选择独立验证组装。

`RootView` 构建底栏；iPhone 和“我的”标签页沿用 `CompatNavigationStack`，iPad 的书库、发现和社区交给 `App/Integrations/BrowseNavigation.swift` 中的 `BrowseNavigationRoot`。iOS 17+ 使用系统 `NavigationSplitView`，iOS 15/16 使用双列 `NavigationView`。尺寸变化不以 if/else 更换主列表视图树，由同一系统容器处理收起和展开。底栏顺序、启动页和上次选择由 `AppTabLayout` 与设置键控制；默认入口为书库、发现、社区和我的。修改导航时同时考虑用户保存的底栏配置和页面返回状态。

`BrowseNavigationRoot` 仅持有当前标签的详情选择、全窗口阅读目标与阅读返回定位请求。页面通过可空环境动作提交浏览选择/发起阅读；未注入时 `BrowseDetailLink`、`BrowseReadingLink` 退回原导航链接，因此手机行为不变。列表点击与菜单阅读分开，云端下载仍走原 `LibraryBookActions`；阅读使用原 Root 注入的所有服务，关闭后刷新位置，`ScrollViewReader` 按书键定位，避免最近阅读排序变化使刚读的书离开视口。详情导航栈仅在选中目标标识变化时重建，旋转或内容宽度变化不重置它。浏览选择不进入磁盘或 WebDAV。

实例所有权分为两类：

- `AppServices` 持有配置、API 集合、小说账号、论坛账号和 `LocalAppServices`；后者持有进度、书签、摘录与笔记、阅读设置、统计、计时控制器、书库状态、标签、背景、云端书目与同步。
- `RootView` 持有并注入收藏、历史、远端文库、网络小说下载和本地文库/导入书库 Store。需要 API 的 Store 在初始化时接收对应服务。

Root 还连接账号恢复、续期注册、账号变化后的收藏刷新、前台恢复与更新检查。把新的启动行为放在正确生命周期中，防止视图重建重复启动任务。页面内的查询状态由页面自己的状态对象持有；共享持久化状态不能随页面销毁而重新创建。

更新检查由 Root 持有的 `NoveliaUpdateStore` 管理，设置页使用同一实例。`Support/ReleaseUpdates.swift` 请求公开仓库的最新正式 Release，以标签与本机 `CFBundleShortVersionString` 比较。版本解析支持字母、短横线或下划线前缀、1–4 段数字、预发布后缀和构建元数据：缺少的数字段按零比较，同号预发布低于正式版，`+` 后的构建元数据不参与比较。“忽略此版本”保存可重新解析的规范化版本号；自动检查遵守开关与忽略记录，手动检查绕过这两项限制。格式兼容由 `ReleaseUpdateTests` 验证。

API 失败时尝试同一仓库的 `/releases/latest` 网页重定向，只从最终 URL 读取标签；最终地址必须满足既有 HTTPS/仓库来源检查，标签必须可解析且没有预发布后缀。不解析 HTML、不使用第三方镜像、不内置 GitHub 令牌。API 和网页均失败时保留 API 原错误；403 且匿名剩余额度为零、或 429，会提示限流，其他失败提示暂时无法获取版本信息。回退与不可信重定向由 `ReleaseUpdateTests` 覆盖。

## 功能实现地图

下表路径除特别标明外均相对 `iOSApp/Features/`。

| 功能 | 主要入口与实现 | 状态与职责 |
|---|---|---|
| 账号 | `Account/AccountAuth.swift` | 登录桥接、统一会话、Keychain 凭据适配与账号状态 |
| 发现与详情 | `Discover/DiscoverViews.swift`、`DiscoverStore.swift`、`NovelDetailViews.swift` | 搜索、排行、标签、分页、详情和评论；调用目录/评论等服务 |
| 书库 | `Library/LibraryViews.swift`、`LibraryStore.swift`、`LibraryComponents.swift`、`LibraryBookActions.swift`、`CharacterSeriesView.swift`、`CharacterCardSupportViews.swift` | 聚合本地记录、查询筛选、系列、排序、批量与菜单动作及跨卷人物资料界面 |
| 收藏与历史 | `Library/FavoritesStore.swift`、`ReadingHistoryStore.swift`、`ShelfViews.swift` | 账号相关远端状态、收藏操作、历史与续读 |
| 文库 | `Wenku/WenkuStore.swift`、`WenkuViews.swift` | 远端文库查询、详情和收藏；本地文件另由书库 Store 管理 |
| 下载与导入 | `Downloads/WebNovelDownloadStore.swift`、`Library/WenkuLocalLibraryStore.swift`、`Library/KindleImport/` | 下载、导入（含 AZW3／MOBI 转 EPUB）、文件位置、记录写入及同步书籍接口 |
| 阅读器 | `Reader/ReaderView.swift`、`TXTReaderView.swift`、`EPUBReader/` | 在线/TXT 滚动与分页、EPUB 阅读、引擎和位置转换 |
| 社区 | `Community/ForumStore.swift`、列表/详情/编辑/Markdown 页面 | 论坛查询、筛选、正文、评论、编辑与链接交互 |
| 统计 | `Statistics/ReadingStatisticsViews.swift`；Core 的 `Features/Statistics/` | 图表与明细、阅读记录、设备统计及合并 |
| 同步 | `Sync/WebDAVSync.swift`；Core 的 `Features/Sync/` | 同步设置与进度、计划、文件传输、清单和统计同步 |
| 设置 | `Settings/SettingsViews.swift`、`BlockedTagsViews.swift` | 偏好、主题、底栏、标签、阅读体验和功能入口 |

共享封面组件位于 `iOSApp/Shared/CoverImage.swift`。日志、更新、设置键与通用哈希位于 Core 的 Support。不要因某文件被多个页面引用就把它的业务职责移动到 Shared 或 Support。

典型调用链如下：

```text
发现页面 → DiscoverStore → NovelCatalogService → API 适配 → Domain 模型
小说详情 → NovelDownloadService → 下载 Store → 文件与索引 → 书库
在线阅读 → 章节缓存 → NovelContentService → 章节内容 → 滚动或分页引擎
阅读操作 → ReaderSettings / ReadingPositionProviding → 本地进度
阅读计时事件 → App 适配 → ReadingActivityController → ReadingTimeRecording
手动同步 / 自动同步触发 → WebDAVSyncStore → 计划与引擎 → 远端接口 + 本地状态接口
```

社区使用 `ForumStore` 持有列表/分类/查询状态，帖子、评论和编辑页面消费 `ForumService`。Core 的 `ForumMarkdown.swift` 提供 Markdown 相关处理、图片分段与链接路由，`ReplyPaging.swift` 提供论坛评论与小说书评共用的“加载更多回复”分页，界面层负责渲染、展开剧透，并按分段结果加载 http/https 图片。图片直接请求 Markdown 里的地址（相对路径相对论坛来源），不经过 `ForumService`。修改富文本或链接时保留配置来源检查、相对链接处理与内部导航，不在渲染组件中建立另一套论坛 API 请求。

设置页面按账号、阅读数据、阅读、界面、同步、关于、高级分组，App 主题色与界面底色位于“界面”；“高级”里另有“显示目录诊断信息”开关与导出应用日志，分组只改变展示，沿用已有绑定与存储键。封面网格按列宽与固定宽高比布局，书名预留两行；各系统版本统一使用带主操作且无预览的 Menu，单击打开书籍或切换选择，长按只展开操作菜单，避免封面抬起和 List 整行网格快照。书库菜单复用既有导入、系列、多选、排序及书籍操作处理，分页阅读设置的字号加减只更新 `draftStyle`，由原有“应用”入口保存与重排。

设置通过 `SettingsKeys.swift` 中的已有键及对应状态对象保存偏好。背景、字体、标签和分章规则有各自的存储/适配；设置界面负责用户操作，阅读器负责消费结果，同步通过 App 适配获取可同步部分。新增设置时明确默认值、已保存值、立即生效范围和是否同步。

### iPad 窗口布局

`NovelDetailView` 在导航内容区通过 GeometryReader 读取实际可用宽度，800 点起并排信息卡和简介；辅助功能大字号保持纵排。只切换无状态展示片段，详情加载与导航仍由外层持有，旋转不重建业务实例。文库详情、论坛帖子详情、阅读设置和听书主面板限制内层内容可读宽度，不限制外层滚动容器、导航栏或阅读视口。阅读统计在常规水平尺寸且非无障碍大字号下将“阅读概览”四项排成双列网格，保留 `CompatLabeledContent` 可访问性标签。译源卡使用自适应网格。书库支持 `.onDrop` 接收分屏拖入的书籍文件（`LibraryImportModel.handleDroppedProviders` 先复制到临时目录再走统一导入与 Kindle 转换确认，结束后清理临时目录），人物卡头像区与编辑页支持拖入角色图片。原生分页引擎 `EPUBReaderModel.scheduleRelayout` 对 `.resize`（分屏或台前调度连续拖拽改变窗口尺寸）做 120ms 防抖，期间保留当前 `pageBook` 与锚点，避免逐帧清空页面重排。`test_api_architecture_ui.py` 的 `testAdaptiveNovelDetailRotation` 检查详情横竖屏编排和边界；`testNativeReaderPanelRotation`、`testReadiumReaderPanelRotation` 检查两种引擎旋转后设置面板的宽度及关闭操作。验证 runner 同时支持 iPhone/iPad；不替代分屏连续缩放和真机阅读位置验收。

`DiscoverView` 以窗口宽度扣除边距并限制内容上限，计算 1–3 个等宽卡片列；大字号退为单列。查询、分页和 `ScrollViewReader` 仍由原层持有。书库 `libraryListRow` 只限制行内内容，不替换 `List` 或拖选坐标系；搜索栏与批量栏保持外层满宽。`LibrarySelectionBar` 在紧凑尺寸类别或辅助功能字号下把计数与两列动作分开；动作共享同一选择状态。UI回归 `testAdaptiveDiscoveryAndLibrarySelection` 检查卡片宽度、导航、多选旋转和各操作可达性。Readium编号合成书的 `testReadiumRotationKeepsVisibleParagraph` 检查章中旋转后的同一正文标记实际可见性，不能外推至任意真实书籍、原生引擎或分屏连续缩放。

Readium宿主在 `viewWillTransition` 调用父类前由模型捕获真实导航器的 Locator，尺寸过渡期间忽略临时位置回报，完成后恢复并等待稳定位置再提交。连续过渡复用最初锚点、取消较早恢复任务；显式翻页/跳转/朗读等通过 `markNavigation` 撤销旧恢复。后台窗口快照不发起恢复；失败时保留进度保护并显示重开入口。`testReadiumRotationKeepsVisibleParagraph` 在章中定位实际正文标记，检查横竖屏和重启恢复；不代表真机、复杂版式、连续分屏缩放或原生引擎已全部验收。

Debug 独立验证 App 可用 `-architectureBrowseResize` 将同一个 Root 内容区切为480点/compact或恢复宽度，检查收起展开与状态保持；仅在独立 bundle id 和架构验证组装同时满足时启用，按钮与标记均不进入 Release，由 `check_architecture_release.py` 检查。此测试改变内容宽度和尺寸类别，不能作为真实 Stage Manager/分屏拖拽验收。第三批UI方法覆盖双栏阅读返回、搜索保留、窄宽切换，以及300本合成书库中的阅读返回定位；截图与实际执行结果保存在仓库外。

### iPad 硬件键盘与指针

`Shared/KeyboardNavigation.swift` 的 `PageKeyAction` 由页面提供操作，`PageKeyboardButtons` 使用 focusedSceneValue 发布当前窗口操作，由 App 的 `PageKeyboardCommands` 在系统菜单中注册 keyboardShortcut 和快捷键说明，页面内的 UIKit 非文本 UIKeyInput 接收器只在当前页空闲时取得焦点，空 inputView 不显示软键盘；文本编辑、非空选区和控件焦点优先。锚点也用于读取本窗口的滚动视口；作用域随页面/窗口生命周期释放，不设全局键盘分发。SwiftUI 弹层在自身注册关闭快捷键，避免后方阅读页响应退出。文本输入或正文选字的 responder 优先，不能为翻页抢走编辑焦点。命令上下文每页稳定持有，只发布可比较的操作说明；回调随页面更新，避免把新闭包数组反复发布到焦点系统。iOS16+用focusedSceneValue，iOS15用非可空focusedValue和同一接收器兼容。书库、发现与社区通过 `browseKeyboardActions` 使用已筛选和排序的目标数组及原有选择/阅读环境动作，不建立第二份状态；云端书目不绕过下载确认。

分页快捷键调用原模型 `commitTurn` / `goForward` / `goBackward`，滚动快捷键移动当前视口的真实 UIScrollView 并暂停朗读跟随，沿用原进度观察。滚动阅读设置仍使用注入的同一 ReaderSettings。`pointerBookMenu` 仅在悬停时提供菜单内容，触摸长按留给原拖选；拖选识别器拒绝 indirectPointer。UI回归用 XCTest 的实际 typeKey 输入，分别覆盖浏览焦点和各阅读引擎；不得把模拟器按键通过外推到真实硬件、VoiceOver 或旧系统运行。

## API、数据模型与认证

### 现有入口

- `Domain/APIServices.swift`：八类服务协议及 `APIServiceCollection`。
- `Infrastructure/API/APIConfiguration.swift`：API、网页来源与认证配置。
- `Infrastructure/API/NoveliaServices.swift`：当前客户端的协议适配与服务集合工厂。
- `App/AppServices.swift`：App 持有服务集合和账号状态；生产入口为 `AppServices.novelia(...)`。
- `Features/Account/AccountAuth.swift`：当前网页登录、会话恢复与续期适配。
- `Domain/SessionTokenStore.swift`：凭据存储接口。

| 能力 | 消费的协议 |
|---|---|
| 搜索、排行榜、小说详情 | `NovelCatalogService` |
| 在线章节 | `NovelContentService` |
| 文库查询与详情 | `WenkuCatalogService` |
| 云端收藏及文件夹 | `FavoritesService` |
| 历史、记录上报与续读 | `ReadingHistoryService` |
| 网络小说与文库 EPUB 下载 | `NovelDownloadService` |
| 书籍评论与回复 | `BookCommentsService` |
| 论坛帖子、评论、编辑与收藏 | `ForumService` |
| 消费方账号状态与匹配 | `AccountSessionProviding` |

页面与 Store 通过初始化参数或 App 环境取得服务。Store 只保存所需协议；不要为了少写参数让所有 Store 依赖整个 `AppServices`。SwiftUI 页面可在外层读取环境，在内层初始化并持有状态对象，沿用现有发现页等方式，保持返回页面后的状态和缓存。

网络小说列表的类型、分级与排序由 Domain 的 `NovelCatalogFilter` 表达，发现页只传枚举，适配层原样转换为站点查询码（类型 0–3、分级 0–2、排序 0/1/2 对应更新/点击/相关）。默认值保持加入筛选前的行为（全部类型、一般向、按更新排序）；分级“全部”和“R18”依赖账号的 R18 权限，401 按原服务端错误呈现。

### 替换 API 的步骤

1. 如果仅地址改变且 API/认证格式兼容，使用 `APIConfiguration` 和当前工厂；网页来源、评论来源与认证入口也必须一致配置。
2. 如果格式或语义改变，在 Infrastructure 中实现需要的服务协议，将响应转换成 Domain 模型。请求字段、分页换算和服务错误处理留在适配层。
3. 在 App 组装处显式构造完整 `APIServiceCollection`。可有意组合多个实现，但不得在缺失能力、请求失败或开发配置错误时偷偷退回生产客户端。
4. 认证协议不同则实现相应认证适配。当前 API 协议仍含 providerId、novelId、分页等站点语义，不能承诺任意后端只换地址就兼容。
5. 用替代服务验证消费方，再对实际服务器进行鉴权、分页、下载和失败恢复联调。

禁止在 Feature 中创建 `NoveliaAPIClient`/`ForumAPIClient`、拼接固定站点 API 地址或发临时 HTTP 请求绕过协议。站点链接路由应使用已有配置与路由逻辑。WebDAV 和发布更新有各自传输职责；不要把所有网络行为硬塞进小说 API 协议。

### 认证不可随意改变的约定

小说与论坛是同一个用户账号，但分别维护 `app=n` 与 `app=f` 会话。书籍评论虽然使用论坛来源，仍使用小说会话。改变这些对应关系必须有后端证据及相关回归。

两种会话用同一个认证站点刷新 Cookie 续期，而该 Cookie 每次续期都会轮换。`AccountAuthStore` 与 `ForumAuthStore` 必须注入同一个 `SerialAsyncGate`（`AppServices` 统一组装），续期逐个执行，后一个读取前一个写回 WebView 的新 Cookie。续期进行中再调用 `refreshSession` 时等待同一结果；退出登录（`sessionGeneration` 变化）后的调用不复用旧结果。登录 WebView 打开配置的小说官网，脚本在官网按钮挂载后自动点击“登录/注册”；找不到时用户可手动点击。桥接只观察官网向认证来源发送的成功登录请求或认证页的成功通知，不读取表单及响应正文。登录网页与认证 API 使用分别校验的 HTTPS origin，不扩大到任意子域。网络续期部分由 `AuthSessionRefresher` 实现，WebView Cookie 存储是唯一来源，请求设置 `httpShouldHandleCookies = false`。

生产账号状态、API token provider 与续期入口使用同一 `SessionTokenStore`。生产适配继续使用原 Keychain/Vault；测试使用内存适配。不要在消费方直接读取 Vault、解析 JWT 判断账号，使用 `AccountSessionProviding` 的状态和 `matchesAccount`。

保留登录桥接的 HTTPS、主框架、来源 host/port 检查、配置校验、受控 JS 数据编码及有界续期/重试。不为测试放宽生产检查，不把真实 token、Cookie 或密码写入代码、日志、测试、文档或记忆库。

## 本地状态与跨功能连接

`LocalAppServices` 组装并持有进度、书签、摘录与笔记、阅读设置、阅读统计、计时控制器、书库状态、标签、背景、云端书目和 WebDAV 同步实例。Root 注入观察对象，阅读器、书库和同步必须使用同一套实例。

`LocalAppServices()` 是生产入口；替代组装使用显式初始化器，必须提供偏好存储、书签、统计、标签、背景、云端书目和 `WebDAVPasswordStore`。不能仅传入隔离 defaults 就假定文件或 Keychain 已隔离。生产继续沿用旧目录、偏好键和 Keychain 服务。Root 向 Feature 注入同一标签／背景对象，页面不得再自行查找它们的共享实例。平台字体注册仍由 `EPUBLocalFonts` 管理，不属于这个容器的隔离契约。

`WebDAVSyncStore` 的设置、自动状态、目录缓存、统计缓存及引擎哈希缓存使用注入的 defaults；密码读写经 `WebDAVPasswordStore`，生产为原 Keychain 适配，测试可注入内存闭包。独立 Debug 验证 App 使用显式组装及内存设备身份／同步密码，不进入生产 Keychain 入口。

不得恢复 `ReaderSettings.shared`、`LibraryStateStore.shared`、`ReadingStatisticsStore.shared`，不得在子页面创建第二套生产状态。`ReadingPositionStore` 与书库排序设置在内存缓存已读取的数据（进度写入仍立即落盘），同一偏好存储出现第二个实例会读到过期进度。测试可使用隔离 `UserDefaults` 构造独立服务；阅读设置与进度应使用相同的注入存储。

| 功能关系 | 应使用的边界 |
|---|---|
| 阅读器/书库读写进度 | `ReadingPositionProviding` |
| 同步合并进度 | `ReadingPositionSynchronizing` |
| 同步书库系列 | `LibrarySeriesManaging` |
| 阅读计时事件 | `ReadingTimeRecording` 与 `ReadingActivityController` |
| 同步统计 | `ReadingStatisticsSyncing` |
| WebDAV 访问 App 本地状态 | `WebDAVSyncLocalState`，由 `AppWebDAVSyncLocalState` 适配 |
| 同步书籍记录 | `SyncBookLibrary` |

阅读计时由 `App/Integrations/ReadingTimeTracking.swift` 连接；同步状态由 `SyncLocalStateAdapter.swift` 连接。阅读器不要导入具体统计 Store 或调用 WebDAV UI 的静态方法。WebDAV Store 不自行查找阅读设置、下载、背景、标签或书库单例。

项目仍保留部分解析、布局、图片缓存和规则等共享服务；生产入口也沿用既有背景与标签共享对象，但页面和同步通过 App 注入的同一对象访问。这不代表新增持久化功能可以继续引入全局单例。修改现有共享服务时核对生命周期、并发与状态隔离，避免为一次小需求全面重写。

## 阅读器实现

阅读内容与排版引擎分开处理。在线内容通过 `NovelContentService` 获取，本地 TXT 由 Core 的 `TXTChapterParser` 和 `TXTBookCache` 处理；EPUB 由 `EPUBContainer` 读取容器、章节和资源。不要把下载或网站认证逻辑放进排版模型。

默认 EPUB 容器的章节读取保留缺失文件、解压／CRC 失败和条目大小上限错误，不统一转换为 OPF 缺失。用户错误说明包含包内路径，日志只记录固定分类。容器打开失败通过模型持有的可取消任务重试；章节失败保留来源以允许重试或从目录跳过。章节图片缺失或解码失败时以 1×1 透明占位继续排版（`EPUBContainer.missingImagePlaceholder`），避免排版引擎因缺资源让整章失败。目录、书签或书内链接跳章成功而状态仍停在失败页时，`markReadyAfterRecovery` 恢复 `.ready`；永久性内容错误（`chapterMissing`／`entryRead`／`chapterIndex`）不写入 `failedChapters`，避免出现重试也无法消除的「相邻章节加载失败」提示。容器只读，不修补原 EPUB。异常合成包回归在 `EPUBFailureTests`；独立验证 App 的 UI 脚本支持 `--epub-failure archive` 和 `--epub-failure chapter`，分别验证打开失败和缺失首章后的恢复入口。脚本仅改写专用验证 App 的样例文件，结束后恢复。

| 实现 | 主要职责 |
|---|---|
| `ReaderView.swift` | 在线滚动阅读、正文/译文选择，以及在线分页入口和章节缓存 |
| `TXTReaderView.swift` | 本地 TXT 阅读入口、目录和滚动/分页模式连接 |
| `EPUBChapterSource.swift` | 章节内容接口、文本转 XHTML、长章节拆分与 TXT 分页定位转换 |
| `EPUBContainer.swift`、`EPUBContentSupport.swift` | EPUB 内容与资源读取、图片解码/背景清理/脚注解析与 NCX 解析，提供章节来源能力 |
| `EPUBPageBook.swift`、`EPUBLayoutCoordinator.swift` | Yuedu 分页内容、布局协调和缓存 |
| `EPUBReaderModel.swift`、`EPUBReaderNavigationSupport.swift`、`EPUBReaderView.swift`、`EPUBSharedTypes.swift`、`EPUBPagerView.swift` | 原生分页模型、导航/朗读/搜索协调、共享视图与翻页交互 |
| `ReadiumTextPublication.swift` | 将 TXT/在线文本章节包装为 Readium Publication，并提供导航索引 |
| `ReadiumEPUBReaderModel.swift`、`ReadiumEPUBReaderSupport.swift`、`ReadiumEPUBReaderView.swift` | Readium 内容加载、导航、书签/搜索/手势与拟真翻页快照、显示和位置连接 |
| `ReaderSettings.swift`、`ReaderSettingsAdapters.swift` | 持久化阅读偏好及引擎/界面适配 |

EPUB 默认采用 YueduCoreText 分页；实验性 Readium 开关可用于 EPUB、TXT 和在线分页，开关默认关闭，已有选择继续保留。TXT 和在线内容也支持滚动模式。引擎选择属于 Reader 内部，API 消费方不根据引擎切换后台实现。

分页起播优先传递 `SpeechAnchor.sourceUTF16Offset` 并标记 `startsAtVisibleOffset`，长句页首在 `SpeechText` 拆分后起播，上一句仍可回退前缀。原生读取 pageBook 页首源偏移；Readium 的 Edge 起播读取实际可见 DOM 文本字符，按去空白 UTF-16 映射并核对引文，匹配失败明确报错，不用排版页比例猜字符位置。本地 Readium 保留官方可见 Locator。底部听书条（`ReaderSpeechBar`）由控制器的会话显示状态管理，准备/暂停/结束/失败均保留，明确停止或离开才收起；根视图另有跨页迷你条 `SpeechMiniBarHost`，观察 `AppServices.speechHandoff`，只在阅读器之外出现。

朗读的文本准备由 Core 的 `SpeechText` 负责：把章节纯文本按中英文句末标点与换行切成片段，连续标点与闭合引号／括号归入当前句，段落内空白合并，无标点长文按 200 个 UTF-16 单元兜底切分；选句起播使用 `SpeechAnchor.sourceUTF16Offset`，章节加载后按真实长度解析；Readium官方TTS直接使用选区Locator，Edge按选区文本匹配原文最近重复位置，无法匹配不猜偏移。选区解析任务归同一控制器所有，停止/换引擎取消，迟到结果丢弃。原生选字菜单通过宿主意图回调起播，Readium编辑动作放在现有容器响应链；高亮点按使用原生矩形/Readium Decoration事件，滚动文本用仅覆盖高亮范围的内部链接，HTTP链接优先。片段记录每个合成 UTF-16 单元到原文的映射，保留折叠空白前的位置；页内跟读使用 `SpeechReadingPosition` 的原文句子范围与当前词偏移，与阅读器提供的文本同一口径，`startIndex` 按章内比例定位起播句。这里只做纯计算，不持有发声对象或音频会话；平台发声与音频焦点属于 App 层，两个目标共用同一实现。

朗读引擎的统一契约在 Domain 的 `SpeechPlaybackContract`：`SpeechEngine` 协议声明能力（`SpeechCapabilities`）、状态（`SpeechPlaybackState`）、起播位置（`SpeechAnchor`）与设置（`SpeechSettings`），界面只依赖契约而不认识具体合成实现。引擎实现放 App 层，可按内容类型选择；新增云端合成引擎时只新增实现，不改阅读器界面。声音偏好 `volume`（0…1，默认1）与 `pitch`（-1…1，默认0）用独立v1键本地保存；按 `volumeControl`、`pitchControl` 能力展示。系统在下一utterance设置volume与2^pitch的pitchMultiplier；Edge音量立即赋给AVAudioPlayer，音高映射为-50…50Hz SSML并进入音频缓存键，改变音高取消旧预取；Readium官方配置不支持，不声明对应能力。试听沿用同一参数。章节跳转与真实句级音频定位分别通过 `chapterNavigation`、`sentenceNavigation` 声明；面板按能力显示章跳转，Edge 有时间轴时按句、无时间轴时按段。词级进度由 `SpeechCapabilities.wordLevelProgress` 声明，`SpeechUtterance.highlightRange(for:)` 对不支持的引擎返回 nil，阅读器实际接通高亮与翻页后另声明 `readingFollow`，面板按此能力显示跟读控件；仅提供词级回调不显示无效开关。网络请求、凭据与音频缓存须放 Core 的 Infrastructure/API，由 App 层组装注入，不在阅读功能里直接发请求。

Readium 阅读器的朗读实现在 `iOSApp/Features/Reader/Speech/ReadiumSpeechPlayback.swift`（界面与音色目录位于同目录 `SpeechPlaybackViews.swift`）：`ReadiumSpeechEngine` 包装 `PublicationSpeechSynthesizer`，由模型在 `makeNavigator` 完成后挂载（导航器重建即换引擎，旧引擎先停止）；起播用 `firstVisibleElementLocator()`，delegate 的 `.playing` 用 `Decoration` 高亮当前句，并对 `range` 做 0.8 秒节流后 `navigator.go(to:)`。`SpeechPlaybackController` 是界面唯一状态源，`SpeechControlView` 按 `capabilities` 显示控件。官方合成器的 `Configuration` 只有默认语言与音色标识，不暴露语速，因此该引擎不声明 `.rateControl`；音频会话由 Readium 内部管理。`ReadiumTextPublication` 为在线／TXT 注册 `DefaultContentService` 和 `HTMLResourceContentIterator`，不在构造或位置索引阶段加载正文；官方 TTS 按需迭代内容，使用同一套 Locator 高亮与跟读。跟读导航通过模型标记 `speech` 来源，进入既有阅读进度链路；用户手动导航只挂起跟读。

系统 TTS 兜底在 `iOSApp/Features/Reader/Speech/SystemSpeechEngine.swift`：`AVSpeechSynthesizer` 逐句朗读 `SpeechText.segments` 的片段，读完一章按 `chapterText` 闭包取下一章；delegate 由独立桥接对象接回主线程，长章节切句在后台线程执行。音频会话由该引擎自己激活／释放，不与 Readium 内部管理的会话复用。`ReaderSpeechPresentation` 挂在 Yuedu 分页 EPUB、在线章节、TXT 滚动阅读宿主上，菜单按钮只改变展示状态；不把 sheet 放在随菜单/顶栏销毁的按钮里。打开面板时才创建引擎以避开阅读器就绪时序。面板允许书内切换本地/Edge，首次Edge先确认发送正文。控制器先截取当前收听锚点、句子文本、Readium Locator与播放意图，再由宿主重建引擎；播放中自动续播，暂停时保存待起播锚点，不启动新合成或云端请求。跨引擎用当前句核对源位置，Readium由模型解析收听锚点，不能重新使用旧可见页。当前引擎类型可观察，语音 Picker 只展示该引擎的音色并按语言分组；固定短句试听通过 `SpeechEngineSelecting.preview` 由 App 工厂注入在线服务，本地试听使用独立系统合成器。试听由控制器持有恢复令牌：临时暂停原书，自然结束或主动结束试听后恢复原意图；离开设置、停止、跳转、换引擎等显式操作取消令牌并停止试听音频。试听对象只释放自己持有的音频会话，避免旧视图销毁时关闭已恢复书籍的音频。音频与合成器回调继续核对身份。正文底部听书条与跨页迷你条复用原控制器；书内保留前后句／播放／定位，跨页只保留书名／播放／返回书内，跳章与停止收在更多。点击文字区打开听书主面板，配置另在第二层。主面板使用实际句首比例展示文字位置，不估计音频时间；语速控件共用SpeechRateControls，用户数据键与归一化范围不变。主要点击区至少44pt。退出阅读器时由 `ReaderSpeechPresentation.handOffOnExit` 移交：系统/云端引擎只依赖正文闭包，交给 `SpeechHandoffStore` 由根视图迷你条继续，重新进入同一本书时接管原音频对象，保持句内播放进度；Readium 官方引擎与阅读模型一并移交，保留导航器继续播放。在线章节按当前原文／译文／双语模式与译源选择正文，按 providerId／novelId／chapterId 走既有 `services.api.content` 接口，不新增请求通道。系统引擎只在 `onReadingPosition` 实际接通时声明 `readingFollow`，停止/结束时发 nil 清理高亮，设置变化时重放当前阅读位置。原生分页的 `speechChapterText` 使用 `EPUBPageBook.sourceText`，避免 HTML 抽取与排版偏移不一致；跟读只定位已准备章节的页面，通过 `moveLocation(cause: "speech")` 保存进度，句子矩形使用独立 CAShapeLayer 绘制，不修改分页位图或选字。滚动模式按原文范围映射既有段落/长文本切片，给 AttributedString 附加底色并用 ScrollViewReader 定位；跨章沿用既有章节进度。用户手动翻页/导航或拖动滚动页挂起跟读，显式返回只定位、恢复跟读才解除挂起；全局关闭跟读时不擅自开启。切换在线阅读模式/译源仍停止。

云端合成通过 Domain 的 `CloudSpeechSynthesizing` 注入，`App/Integrations/SpeechEngineFactory.swift` 在 App 层选择本地或 Edge；只有生产组装提供 `EdgeSpeechClient`，替代验证组装不联网。`SpeechEngineSelecting` 让分页/滚动只提供惰性正文，不直接请求具体客户端。默认偏好保留 system/readium 本地自动路由；选择 edge 仍需 `speech.edgeConsent.v1` 明确同意，缺失同意时回退本地。普通设置/播放入口不自动请求音色目录；用户在“更多 Edge 音色”中明确点更新才通过 `SpeechEngineSelecting.refreshVoices`、App工厂和现有匿名Edge客户端获取目录，不发送正文。目录最多2000项/2MiB，经标识、字段长度和去重验证后以公开元数据缓存到本机；失败不清空缓存，坏缓存回到内置列表，旧的有效动态选择保留。地区音色转SSML时地区后缀纳入locale。内置常用音色，Edge 音色使用独立持久化键以保留本地语音选择。

`EdgeSpeechClient` 用独立 ephemeral URLSession，不携带小说/论坛账号或已有 Cookie，不使用磁盘缓存；采用当前 v2 时间令牌与 WebSocket MP3 帧，45 秒超时、8MiB 响应上限、取消立即关闭连接，仅服务 Date 显示时钟误差时纠正一次。协议与时间令牌适配参考 LGPL-3.0-only 的 rany2/edge-tts，固定来源和修改声明见 `docs/LICENSES.md`。`EdgeSpeechEngine` 用 AVAudioPlayer 播放有界分段音频，重用起播/取消代次及播放器身份检查；云端合成中暂停不会在返回后播放。用户明确开启 `edgePrefetchEnabled`（默认 false，独立持久化键）后，同章最多提前预取下一段、最多一个预取任务；前台到达该段复用同一在途任务与 LRU 缓存，停止、暂停或音色/语速变更取消旧预取并用独立音频代次拒绝迟到结果。不预读下一章、不写文件。临时传输失败最多延迟重试一次，协议/配置错误直接失败；失败保留当前段，播放按钮原地重试，不静默略过。每段由 `CloudSpeechText` 按最多约 3KB XML 转义 UTF-8 合并本地句子，前后操作有时间轴时按句在同一音频内定位，跨段回退读取上一段末句，无时间轴时按段切换；不声明 wordLevelProgress。客户端启用 SentenceBoundary 元数据，`CloudSpeechAudio` 带音频和真实句子时间轴；`CloudSpeechText.Chunk` 保留合成文本每个 UTF-16 单元的原文位置。播放器按 currentTime 消费句子时间轴，已接通阅读位置回调时声明 readingFollow；没有元数据或无法匹配正文时不推测精确位置。原生/滚动复用已有原文范围高亮，Readium 用句子及前后文构建 Locator、Decoration 与跟读；异步定位在新句/停止时取消，暂停不再推进页面。音频与时间轴只在该引擎当前会话内以音频最多 8MiB 的 LRU 缓存保存，stop 清空；无文件缓存与凭据。网络/协议错误明确失败，不静默改用另一在线服务。


续听位置由 Core 的 `SpeechResumePoint` / `SpeechResumeStore` 按书保存（键前缀 `speech.resume.v1.`＋书籍身份）：保存实际章号、句首源偏移、章内比例及可选的 Readium Locator JSON；新增字段可选，旧记录继续按比例恢复，缺键或解码失败当作没有记录。播放期间同章至少间隔 60 秒、换章至少间隔 5 秒保存；暂停、停止、离开阅读器或切后台补存，重复位置不重复写盘。阅读器入口需为控制器设置 `bookKey`，并在面板里提供 `onResumeSaved`（跳章并起播）与 `onJumpToSpoken`（回到当前朗读句：原生分页走 `jumpToSpeechPosition`，Readium 用引擎上报的 Locator，滚动阅读定位到对应正文块）。跨页移交时 `SpeechHandoffStore.adopt(_:retained:)` 额外保留阅读器模型：Readium 官方引擎绑定导航器，模型被释放会立即失效，保留后退出阅读器仍能继续朗读。

朗读偏好由 Core 的 `SpeechSettingsStore` 持久化到 `SettingsKey.Speech`：语音标识、归一化语速、跟读两个开关、引擎选择、Edge 独立音色和定时停止分钟数。键名已上设备，不可更改，`SettingsKeysTests` 会锁定。读取先取 `SpeechSettings.default` 再逐项覆盖，缺键、类型错误、无法识别的引擎 rawValue、NaN 与越界数值都安全回落；`SpeechSettings.clamped()` 同时把语速收敛到 0–1、把定时分钟数收敛到固定档位。`SpeechSleepTimer` 只做截止时间与剩余时间的纯计算。这些设置只存本机，不参与 WebDAV 同步；与设置页既有的 `@AppStorage` 简单偏好同一口径，`SpeechSettingsStore` 只是无状态的读写器，不新建共享对象、不恢复全局单例。云端引擎的凭据与音频缓存仍属于 Core 的 Infrastructure/API。`SpeechPlaybackController` 打开时加载、每次 `settings` 变化立即写回，并按书持有 `SpeechRemoteSession`，不设全局单例。

后台与锁屏控制在 `iOSApp/Features/Reader/Speech/SpeechRemoteSession.swift`：两份 Info.plist 都开启 `UIBackgroundModes = audio`；会话注册 `MPRemoteCommandCenter` 的播放／暂停／切换与上一句／下一句、发布 `MPNowPlayingInfoCenter` 的书名与当前句，监听 `AVAudioSession` 的中断通知（`.began` 暂停、`.shouldResume` 继续）与路线变化（拔掉耳机暂停），并用主线程 `Timer` 驱动定时停止。回调只通过闭包接到控制器，引擎不认识该类；`stop()`、跨页移交回收与阅读器 `onDisappear` 会注销命令、观察者与锁屏信息，避免残留无效控件。“我的 → 阅读体验 → 朗读”（`SpeechSettingsView`）与朗读面板共用同一 `SpeechSettingsStore`；关闭面板只收起界面、朗读继续，正在播放时重新打开面板不重建引擎。停止不再绑定阅读器宿主退出（改为按引擎能力移交），也不能绑定会随顶栏隐藏而移除的入口。控制器持有并取消起播任务，控制器与引擎用会话代次丢弃迟到结果；系统合成回调另核对当前 utterance 身份，防止停止／跳句后旧回调继续推进队列。Readium 异步取得起播 Locator 后同样检查代次。远程“播放”在暂停时恢复，结束／失败时从上次起播位置重播，准备／播放中不重复起播；已注销会话的排队命令不再执行。
`NoveliaLegacy` 定义 `NOVELIA_READIUM_ONLY`。它不编译 `EPUBLayoutCoordinator.swift`、`EPUBPageBook.swift`、`EPUBPagerView.swift`、`EPUBReaderModel.swift`、`EPUBReaderNavigationSupport.swift`，阅读入口只创建 Readium 阅读器，设置里没有切回原生分页的开关。字体注册与 `EPUBReaderStyle` 在 `EPUBSharedTypes.swift`，两个目标都编译。iOS 16/17 才有的 SwiftUI 调用集中在 `iOSApp/Shared/IOS15Compat.swift`：iOS 17 走原来的系统控件，更低版本走降级实现。该目标也不编译 Kindle 转换源文件，因为 `Vendor/CLibMobi` 的平台声明仍是 iOS 17。

Readium 深浅色切换通过同一导航器的 `submitPreferences` 更新，不为主题重建导航器；默认文字色沿用 Readium，避免静态 RS 文字色导致切回浅色仍沿用深色默认值。主题变化后重用外层背景缓存。原书双向切换点按回归及 `testReadiumThemeSwitchPreservesCenterTap` 验证控件可隐藏/恢复；模拟器证据不代替真机验收。

“忽略白色底色”同时通过 `EPUBReadiumPageBackground` 清除正文 html/body、段落及行内元素的近白背景（三通道均不低于240）。只覆盖 background-color，保留图片、彩色底及边框；保存原行内值/优先级，选择“保留背景图片”时恢复。设置键、默认值和阈值不变。处理在加载/规则变化时执行；页面内观察仅响应根 style 的实际 `--USER__appearance` 变化，以处理深色开启后切浅色的白底，忽略自身背景修改和其他属性变化。同配置不重复写DOM，关闭规则断开观察；位置/显示回报只使用颜色缓存，自定义背景变化不重提分页偏好。旧导航器/旧规则的异步结果丢弃，不加入夜间文字覆盖。设置界面标题为“书页底色与阅读背景”。

Readium 的 HTML 根背景设为透明，阅读背景由宿主绘制在导航器之下。导航器根视图在 viewDidLoad 时会涂成主题底色，而首次打开不会触发 `presentationDidChange`，因此 `makeWebViewsTransparent` 在每次位置变化时一并清空根视图，否则 WebView 四周的边距会露出白底。WebView 只占去掉上下边距后的区域，外面包着整屏高的章节视图（`EPUBSpreadView`）。书籍给 html/body 设了不透明底色（例如标题页的整页配色）时，每个 WebView 加载完成后（观察 `isLoading`，相邻章节预加载时即完成）读取计算底色，并涂在它所在的章节视图上；边距颜色因此随书页一起滑入滑出，不等位置回报。不能在 `setupUserScripts` 注入脚本取色：该回调时 WebView 已开始加载，脚本不保证作用于当页。是否铺满由 `ReaderBookBackgroundFollow`（`SettingsKey.readerBookBackgroundFollow`，“我的 → 阅读体验 → 书页底色与阅读背景”）决定：默认 `ignoreNearWhite` 忽略三个分量都不低于 240 的白色／米白底色；`keepBackgroundImage` 在当前深浅色与横竖屏设有阅读背景图片时不铺满。该设置只存本机，不参与同步。

在线章节缓存需要保持相同请求的合并、成功内容复用和失败后的重试。长 TXT/章节采用拆分与导航索引，修改时关注首屏耗时、索引构建次数和内存，避免每次翻页重复扫描全书。

阅读位置有内容身份与引擎位置两个层次。持久化模型位于 Domain，进度由 `ReadingPositionStore` 管理；TXT 分页单元、EPUB spine/offset 和 Readium locator 的转换留在阅读实现。改变拆分策略或 locator 映射时检查旧进度、字号变化、旋转、目录跳转和引擎切换后的定位。

### TXT 手工目录

`ReaderSettings.txtAdjustments` 持有 `TXTChapterAdjustmentStore`，生产目录为 Application Support/TXTChapterAdjustments，替代组装使用隔离目录。`TXTAdjustmentDocument` 只调整规范化原文上的 UTF-16 边界，删除边界不删除文字。自动基线由 `TXTChapterParser.adjustmentBoundaries` 直接使用识别出的行号生成，不按标题全书反查。原有自动解析与缓存格式保持不变；有手工快照时 `ReaderSettings.txtBook` 应用边界，规则指纹加入调整 revision，分页缓存与 Readium Locator 因此自然失效。

`TXTChapterAdjustmentView` 从滚动/原生/Readium 菜单进入独立的只读原文选区页，每次装载至多约 12000 个 UTF-16 单元并对齐完整字符。选区在同章内直接生成边界，章首更新标题，首章不可删除。跨原文分段的选择需调整选区，当前不提供跨分段拖选。持久化按文件哈希保存，修订号 CAS 拒绝迟到编辑；撤销仅持有本次会话内的历史边界与不可变文本。

`TXTAdjustmentMigration` 读取同一进度/书签实例，在后台按原 UTF-8 分页切分构建原文段落坐标。章末标题或修剪后没有正文时仍保留一个零长度单元，位置落在该章起点，不把这种目录判成无法对应。现有书签以分页单元/比例保存，承接精度不高于原记录；文字替换改变段长时只在该段内近似映射。目录与待承接状态一起原子提交，之后经时间合并应用；进程中断或书签落盘失败，下次打开重放迁移，不覆盖更晚的修改与墓碑。目录打开前停止朗读，目录变化时一次性清理本书失效的旧续听点。分页回调在调整页显示期间停止写入旧目录位置。手工目录暂不参与 WebDAV，跨设备目录兼容不在当前契约内。

对应 Core 行为与持久化回归位于 `TXTChapterAdjustmentTests`；分页/滚动迁移与 UIKit 选区仍需 App 编译、UI 及真机验证。架构检查不能替代上述验证。

TXT 导出为 EPUB 由 `TXTEPUBExportService` 解析书库文件与阅读设置：复用 `TXTChapterAdjustmentStore.session` 的已保存手工边界，按 `ReaderSettings.bookPreferences["txt:" + 文件哈希]` 读取本书文字投影，再交给 `TXTEPUBExporter` 生成最小 EPUB 3（mimetype、container、OPF、nav、NCX、CSS 和每章 XHTML，卷名嵌套在 nav/NCX 中）。导出只读源文件，不写进度、书签或源文件；临时文件在分享面板关闭后删除。没有手工快照或文件已变化时回退到自动分章。`NoveliaEPUBTests` 的 `TXTEPUBExportTests` 覆盖手工标题、卷名、转义、文字投影和 mimetype 顺序。

### 文本分页与按需加载

`TextChapterSource` 将 TXT 或在线内容转为经过转义的 XHTML 段落，供章节接口消费。TXT 长章节拆为分页单元，仅章节起始单元进入目录；不要把 XHTML 标签长度当成源文本偏移。拆分和定位同时涉及 UTF-8、UTF-16 与章节索引，修改时验证 emoji、组合字符、卷标题、无标题全文和分章规则变化。

Readium 分页使用两层横向滚动视图：章节 WebView 自己的滚动视图负责章内翻页，外层分页视图负责切换章节。拖动从 WebView 以外开始（上下页边距、章节标题栏区域）时只有外层响应，会直接切到相邻章节并跳过本章剩余页面。`ReadiumEPUBReaderModel.swipeBegan` 在外层拖动开始时检查当前章节在该方向是否还有页面：有就取消这次拖动并用 `goLeft`／`goRight` 章内翻一页，已在章首或章末时保留切章。回归为 `scripts/test_api_architecture_ui.py --epub-pagination` 中的 `testReadiumMidChapterSwipesStayInChapter`（章中部在不同高度含页边距滑动）。

`ReadiumTextPublication` 直接把惰性单元包装成 Publication 的 readingOrder，通过 Resource 按需生成内容，不临时打包 EPUB，不提前获取全书正文。生成的 TXT/在线书籍不执行 EPUB 全书资源诊断。位置服务为每个单元提供一个位置，位置数不是实际页数；显示整书比例时还需结合单元内 progression。

在线阅读沿用原文、译文、双语及译源选择，保留缺译提示。双语段内顺序由 ReaderBilingualOrder 和本机 readerBilingualOrder 偏好控制，默认原文在前；显示、搜索文本、朗读及偏移映射共用同一顺序，分页书身份含排列设置。原文使用次要色、译文使用正文色，颜色不随排列交换；切换排列停止朗读，滚动清理旧搜索定位，分页从当前章开头重建。此偏好不参与 WebDAV。进度、书签和服务端历史仍为章节级；显示模式或译源改变时从该章开头恢复，不能把一份译文的字符偏移直接套用到其他正文。正文 HTTP/HTTPS 链接通过既有打开方式处理，EPUB 包内链接另行解析。

Resource 每次请求重新创建，避免将一次加载失败固化为缓存结果。EPUB 文件在创建 Readium Publication 前必须先走 `EPUBContainer.open` 与 `validateForReadium()`（校验 spine 完整性、章节条目 CRC 与解压长度），失败直接进入 `.failed`；Readium navigator 在加载期或运行期报资源失败时用 `didFailToLoadResourceAt` 转失败页并保留「重新打开 / 复制错误说明 / 关闭阅读器」，不能停在加载态。`EPUBContainer.chapterHTML(at:)` 与 `validateForReadium()` 都不能解压图片，避免打开变慢。重试可以重建 Readium 导航器并恢复失败位置；章节请求、位置换算和预取保持取消检查，不能让旧请求覆盖当前章节，也不能为翻页阻塞主线程。

### 阅读器界面共用组件

阅读器界面中跨引擎的部分集中在 `iOSApp/Features/Reader/ReaderChromeSupport.swift`：`ReaderPositionLabel` 负责底栏位置的三态切换（`reader.positionStyle` 偏好），`ReaderTOCRow` 是 EPUB、TXT 与在线小说共用的目录行（层级缩进、当前章竖条与“当前”标签、可选展开列与副标题），`ReaderStyleSheet` 是两个分页引擎共用的“阅读设置”面板（只编辑草稿样式，能否立即重排由调用方引擎状态决定），`ReaderScrubber` 是两个分页引擎共用的底栏进度拖动条（细轨道加小圆点，替代系统滑杆的大旋钮；拖动只更新预览、松手才 `seek`，VoiceOver 通过可调节动作走完整的一次提交），`ReaderTopBarShell`／`ReaderBottomBarShell`／`ReaderPositionRow` 是两引擎共用的顶栏骨架、底栏容器与位置行（菜单内容与显隐策略留在各引擎：原生顶栏用 opacity＋禁用淡出，Readium 用条件包含；原生底栏隐藏时垫页面纸色，Readium 保持透明；Readium 未就绪时整行不可用），`ReaderDebugOptions.showsTOCDiagnosticsKey` 控制目录诊断说明与 `spine N` 副标题（默认关闭）。调整这些组件时同时核对默认引擎、Readium、TXT 滚动与在线小说分页，不要新增第三套样式或入口。在线小说章节目录以半屏卡片呈现，搜索与倒序只影响显示，跳转仍使用原始章节序号。两种分页引擎的阅读页顶栏统一为“书名＋当前章节”两行，底栏分两行（位置、进度条与百分比；电量与时间），工具栏隐藏时保留位置与百分比；拖动进度条只预览目标位置，松手才 `seek`，预览章节名依赖 `EPUBReaderModel.chapterTitle(forProgress:)`，Readium 只有全书百分比。底栏默认只显示页码（`pageDescription`），开启「显示目录诊断信息」后才用 `locationDescription` 附带 spine 与 gen 编号。

### 书签与书内搜索

文库与普通导入书籍的书签（`ReaderBookmark`，Domain）以阅读位置身份 `epub:<哈希>`／`txt:<哈希>` 归属书籍，位置为章节加章内比例，两种引擎都用 `jump(toChapter:progression:)` 跳转；在线小说没有书签身份（`bookmarkKey` 为 nil），沿用在线阅读器的章节书签。`currentPageRange` 给出当前页在章内的比例范围：Yuedu 取页首与下一页的源文本偏移，Readium 按该章位置数估计页宽。书内搜索由 Core 的 `BookTextSearch` 逐章提取纯文本完成，提取规则与 `EPUBChapterProgress.textLength` 一致，使比例与阅读位置同一口径；只搜索本机内容，最多 500 条。两种引擎共用 `ReaderBookmarksSearchSheet` 与 `ReaderBookmarkButton`。已核对的网络小说 EPUB 使用稳定小说及章节身份，见[章节同步与更新](#网络小说-epub-章节同步与更新)。

### 摘录与笔记

摘录与笔记由 Core 的 `ReaderAnnotation`、`ReaderAnnotationStore` 与 `ReaderAnnotationResolver`（`Features/Reader/`）实现，`ReaderSettings` 持有唯一 Store 并注入两种分页引擎。标注保存书籍键、章节序号、稳定章节 ID（网络小说）、资源路径（EPUB）、章内 UTF-16 范围、引文、前后文和章内比例；页码、视图矩形与分页偏移都不持久化。定位先尝试原范围是否仍匹配引文，否则按引文出现位置与前后文共同打分，仍有多个同分候选时用章内比例决定，无法区分则暂不显示。同一章内范围重叠只保留最新一条，完全相同范围更新颜色与笔记；每本最多 1000 条，引文 500 UTF-16、笔记 4000 UTF-16。

原生分页由 `EPUBReaderModel` 从 `EPUBPageBook.sourceText` 和 `selectionRects` 计算当前页矩形，`EPUBPagerView` 在选中菜单提供“高亮／添加笔记”，点按优先命中标注再处理链接；Readium 通过 `editingActions` 和 `ReadiumNavigatorContainer` 的选择器提交选中文字，在 `chapterPlainText` 中按引文求 UTF-16 偏移，再用 `Decoration.Style.highlight(tint:)` 在当前章的 `user-annotations` 分组渲染，点按高亮打开同一个编辑面板。两种引擎共用 `AnnotationEditor.swift` 与 `ReaderAnnotationsSheet`（列表、跳转、左滑删除、Markdown 导出）。TXT 滚动模式不创建标注；创建入口只在分页阅读。

同步在清单 `annotations` 中保存 `[标注 ID: 标注]`，含删除墓碑。`ReaderAnnotation.mergedSync` 先按 ID 与 `updatedAt` 合并，再校验键与 ID 一致、范围与文本有效、单条编码不超过 16 KiB，总量超过 20000 条时只保留最近更新；`WebDAVSyncPlanner.annotationsToSync` 只保留清单中仍有 EPUB/TXT 文件的书籍。清单写成功后才经 `WebDAVSyncLocalState.applyAnnotations` 套用到本机 Store。自动同步指纹包含标注记录，`ReaderAnnotationStore.$records` 变化经 `WebDAVAutoSyncTriggers` 转入延迟推送。


字数口径与缓存在 Core 的 `BookWordCount.swift`：`BookWordCount` 仿 Word 计数（中日文字符与全角／中文标点逐字计，其余连续非空白字符计一词，弯引号等共用标点紧跟单词时并入该词），XHTML 先去掉 head/script/style、注释与 `<rt>`／`<rp>`，标签视为分隔，实体按 `BookTextSearch.decodeEntities` 解码；`tocCounts` 把 spine 字数按“到下一个更靠后的目录项为止”分给目录项，同一 spine 的后续条目不计。`BookWordCountCache` 以文件内容哈希为键，写在 Caches `BookWordCounts/`（版本不符视为未命中，超过 2000 个文件删最旧），并合并同一哈希的并发统计；修改口径时提高 `ruleVersion`。`Reader/BookWordCounter.swift` 是 App 入口：EPUB 由 `EPUBReader/EPUBWordCount.swift` 打开独立容器逐 spine 统计（不与阅读中的容器共享诊断计数，读取失败的章计 0），TXT 直接用 `TXTTextDecoder` 解码，不经过 `TXTBookCache`，避免书库批量统计挤掉阅读中的书。TXT 各章字数随分章规则变化，由打开方从已解析的书现算（`PagedTextBook.tocWordCounts`），只缓存全书字数。书库的 `Library/LibraryWordCounts.swift`（`LibraryWordCountStore`，Root 持有并注入）在行出现时登记、一次统计一本、后登记先算，行消失时撤回未开始的请求；云端书籍只读缓存。阅读器在打开目录时才统计，在线小说不统计。字数缓存属于可重建数据，不写入书库索引，也不同步。

书内图片由 `Reader/ReaderImageViewer.swift` 提供，两种引擎共用：`ReaderImageLibrary` 由阅读器模型持有，EPUB 打开后挂上 `EPUBContainer`（Readium 复用打开前预检的容器），图片一律从 ZIP 读取原始数据，经 `EPUBImageDecoding` 在后台按需缩小解码并缓存，不使用排版引擎持有的位图；TXT 与在线小说不挂容器，不显示图片入口。`EPUBContainer.allImages` 按 spine 顺序收集各章 `<img>`／SVG `<image>`，再补上 manifest 中未被引用的图片，长边不足 120 像素的小图（注释标记、外字等）不列入；首次进入目录页“图片”或首次点图时在后台收集，之后复用。点图只在页面中部三分之一生效，左右两侧仍翻页：Yuedu 由 `EPUBPageBook.imageSource(at:for:)` 从当前页 DisplayList 找到图片 src（不含背景图与边长不足 32pt 的小图），按章节路径解析；Readium 在点按观察者中用 `elementFromPoint` 取 `<img>`／`<image>` 的地址，再由 `EPUBContainer.packagePath(forImageURL:)` 换算包内路径。查看器为全屏 `UIScrollView` 缩放（1～5 倍，双击放大或还原），可左右切换、分享，并可跳到图片所在章节开头；Readium 的 readingOrder 可能不含非线性条目，跳转按文件路径把 spine 序号换算为 readingOrder 序号。目录面板顶部的“目录／图片”切换只在有图片来源时显示；网格内打开的查看器由网格自身呈现，避免与已弹出的目录面板冲突。

书内图片由 `Reader/ReaderImageViewer.swift` 提供：`ReaderImageLibrary`（阅读器模型各持有一个，EPUB 打开后挂上 `EPUBContainer`；Readium 复用打开前预检的原生容器）按需收集全书图片并后台解码、缓存；`ReaderImageViewer` 为全屏查看器（`UIScrollView` 缩放 1～5 倍），`ReaderImageGallery` 为目录页“图片”网格，`ReaderImagePresenter` 在阅读页呈现点图结果。图片列表来自 `EPUBContainer.allImages`：按 spine 顺序读取章节引用（`imageSources`／`resolveImagePath`，与排版取图同一规则），长边小于 120 像素的小图不列入，再补 manifest 中未引用的图片；`spineIndex` 是原生容器的 spine 序号，Readium 跳转时按文件路径换算为 readingOrder。“跳到原文位置”：Yuedu 用 `jump(toImage:)` 排完目标章后由 `EPUBPageBook.pageIndex(spineIndex:containingImagePath:chapterHref:)` 找到含该图的页；Readium 先打开所在章节，再在页面中按解析后的路径找到图片，借 `readium.scrollToLocator` 的 `cssSelector` 定位翻到该页（内容未就绪时短暂重试，找不到则停在章首）。点图只在页面中部三分之一生效：Yuedu 由 `EPUBPageBook.imageSource(at:for:)` 从显示列表命中非背景图片；Readium 在中部点按观察者里对当前可见 WebView 执行 `elementFromPoint`，取 `<img>`／SVG `<image>` 地址，经 `packagePath(forImageURL:)` 映射回包内路径（图片包在链接里时 Readium 视为可交互元素，不转发点按，按链接处理）。查看器盖住阅读页会触发其消失与重新出现，打开流程须保持只执行一次（Readium `open` 以 `status == .idle` 防重入）。书签随书籍同步写入清单 `bookmarks`，按 ID 与 `updatedAt` 合并、远端记录先校验，只上传清单中书籍的书签，清单写入成功后才套用到本机。

### 进度恢复与设置兼容

TXT 的共享位置使用 `txt:<内容哈希>`，保存章节、单元、偏移及单元数。`TXTReadingPosition.pagedStart(in:)` 在单元数量仍匹配时恢复分页位置，否则回退章节起点；同章节滚动位置更新保留分页信息，跨章节后清除失效的单元位置。保留旧 `txtReadingPosition.v1.<hash>` 的读取兼容。

TXT 的 Readium 精确 Locator 使用内容哈希和分章规则指纹作为身份。仅当 Locator 时间不早于共享进度、且资源属于当前单元时优先使用；否则由共享单元/偏移换算为章内比例。打开恢复不刷新同步时间戳；翻页后的异步偏移换算只应用于仍有效的当前位置。听书进度的异步换算与这次翻页写入共用代次，后发起的请求生效，先完成的过期任务不能把进度写回去。跨引擎、跨设备恢复是近似位置，不能承诺落在完全相同的页面。

所有阅读方式都遵守“打开或恢复不写入同步位置”：同步前打开书若用当前时间写入，会让本机旧进度在下次同步时盖过其他设备较新的进度。Yuedu 用 `isRestoringPosition` 包住打开与旧版整书比例的 `seek(restoring:)`，重排期间由计数 `activeRelayouts` 屏蔽位置写入（新重排取消旧重排时不能用保存/恢复布尔值，否则旧任务收尾会把状态写乱）；Readium EPUB 跳过导航器报告的第一个位置及重复位置；在线小说用 `ReaderSettings.isRestoringWebPosition` 判断打开所在章节是否只是恢复，明确选择其他章节才记录。新增阅读入口时保持这一规则。

EPUB 本机 Readium Locator 与共享 spine/章内比例分别保存；共享进度较新时按其恢复。Yuedu 使用源文本偏移，旧记录仍可按整书比例回退。不同来源的时间判断和偏移规则以各实现为准，不为了统一模型而删除兼容字段。

共享字号范围为 12–36。读取时优先全局字号，缺失时读取旧 EPUB 样式，再回退默认值；仅读取不写入迁移，调整字号时更新原全局键与旧样式中的字号并保留其他字段。外观、背景、`readerPagedText`、`readerEPUBReadium` 和 `epubPrototype.*` 等键继续兼容。EPUB 专属行段间距、缩进、边距、字体和双页设置留在已有样式对象。

### 原生分页、缓存与资源边界

原生引擎精确锁定 YueduCoreText 0.18.1。每个章节请求的后台 actor 负责解析、能力检查、旧文本映射准备；`BrowserPageLayoutOwner` 独占会话并准备、逐页排版。主线程只接收不可变页面、构建显示列表和发布状态。取消等待者的规则仍由协调器决定，最后一个等待者离开才取消底层任务；owner 的取消信号可中断正在执行的布局。表格样式不再全量剥离；没有真实 table 元素且被以 table 拒绝的伪表格章节，才把 CSS 的 table 角色降级为 block，并在目录诊断中报告已排版的降级章节数。真实表格支持范围以引擎能力检查为准：不支持的跨行、嵌套、折叠边框和竖排表格仍可能失败。

持久化的 `chapterOffset` 保持旧版无图片字符、括号注音的口径；章节结果以 UTF-16 文本边界映射到新版文本，不原地批量重写进度。EPUB 用户翻页时同时保存可缺省的 `nativeChapterOffset`、`nativeSourceHash`；源文本摘要一致时优先恢复精确偏移，使纯图片页也能恢复到自身，摘要不同时用旧偏移映射。旧客户端和 Legacy 忽略新增字段，原字段仍可读取；恢复及重排不更新同步时间。TXT／在线回调继续使用旧偏移。搜索仍只提取本地文本，跳转时才把命中范围换算到实际引擎文本，避免为搜索排完全书。

原生翻页由 `EPUBPagerContainer` 通过标准子控制器关系持有系统 `UIPageViewController.pageCurl`。`reader.nativePageCurl.v1` 为本机偏好，默认false；Readium不消费该偏好。SwiftUI仅让分页桥忽略安全区，控件保持外层overlay；仿真翻页时底栏材质铺到屏幕下缘，控件内容仍避让安全区，否则底部安全区会露出正在卷动的纸面。全屏纸面按安全区原点放入既有正文位图，正文排版尺寸、选字/链接/图片命中坐标保持原样；搜索矩形做同一偏移。三张有限快照在动画前合成，动画中冻结并缓存输入，完成才提交模型位置，取消不提交；落页等待模型目标位图，拒绝提交前旧当前页重放。系统pan迁移到共同祖先，长按选字优先；点按仍走既有链接/注脚/朗读高亮/中部菜单规则。动画中交互高亮不悬在纸面上，结束恢复。双页是整幅卷动，不是中缝书脊；不修改UIKit内部子视图或使用负安全区。

Readium 的 `ReadiumPageCurlController` 由导航器宿主持有，使用系统 pageCurl 和公共 WebKit 快照 API。独立本机偏好 `reader.readiumPageCurl.v1` 默认 false。真实 WebView 保留正文交互；宿主另持一个复用同一 Publication、字体、边距与配置的预取导航器，当前纸面直接截取已呈现的真实正文，先准备用户请求或偏好的一个方向；同一后台工作流补齐另一侧后，再沿阅读方向额外预热一页（最多四幅纸面）。方向状态单独区分未准备与已确认边界；只有两侧均确认后启用系统跟手手势，部分就绪时由冷手势保留单次请求，缺失方向按需提升为前台准备并复用现有纸面。用户已翻向就绪侧时取消旧页的另一侧补齐，让工作流直接准备目标页的后继，不让首次翻页等待无用的反向工作。补齐邻页时刷新系统公开数据源，避免缓存空邻页。影子导航器的 Readium 前/后位置预加载数量收敛为各1，保留跨章向后定位所需的邻章，不复制真实导航器默认前2/后6的预加载范围；真实阅读导航器保持原配置。全部关闭会使冷跨章向后定位错误落到章首，不能采用。预取导航器的位置回调不能进入真实模型的进度、统计或诊断，真实导航器只截取当前已显示内容，不参与相邻页预取导航；取消时不移动真实导航器；落页先以快照重建纸面并放行下一段动画，真实导航器在单一有序提交任务中逐页追赶，等待 Readium 正式 Locator 更新再发布并保存；屏幕最多领先已提交位置两页，达到上限时暂缓新的卷页动画，取消、旋转与离开先把显示页提交掉再结束会话，提交失败回到最后已提交页并重新准备。样式缓存键使用排序 JSON，避免相同样式反复失效。目录、搜索、进度与样式变化先等待事务结束；旋转取消在途手势并使快照失效，系统旋转过渡完成前不重建纸面或刷新邻页数据源。首方向就绪后，独立后台任务串行补齐另一侧并提前预热阅读方向的下一页，不占用真实阅读事务或锁住正文；快速连续翻页时，预热、落页提交与系统卷页动画重叠执行，动画结束后不再等待上一页的 go + 稳定采样。完成落页后直接把已预热纸面重新编号并复用，不再串行补拍；未命中或预热失败才回退到原有单侧准备。反向、旋转、样式和导航变化会取消旧预热任务，清理阶段等待旧导航结束；过期任务只访问其捕获的独立导航器，不能误截真实正文。全书本地资源诊断只在启用诊断说明且实际打开目录时扫描，关闭目录取消在途扫描，正常首屏不自动读取全书。首次进入和重排只在首方向就绪前等待必要的邻页；其他页面在空闲时补齐。首次进入先等待真实正文字体/布局稳定及轻量 WebKit 呈现屏障（1×1 快照），然后创建独立预取导航器；首屏检查对应的位置和布局仍匹配时，当前纸面截取省略重复的稳定等待，避免第二套 WebView 抢占首屏。首屏 WebKit 冷启动有独立的可取消就绪预算（上限20秒），就绪立即结束；邻页仍用较短预算，不增加固定延迟。旋转和样式变化也按方向分批重建，但独立准备不显示遮挡正文的纸面或加载层，正文就绪即可点按中心控件，边缘点按和横滑请求保留至准备完成。动画及真实落页期间的连续操作按先进先出保留最多两个翻页方向，且只有当前动画期间仍收到新输入才继续消费队列；用户停手后不再回放旧方向，超出上限丢弃最早意图，不要求重复操作；取消、准备失败与离开会清除排队请求。卷页动画期间由不参与手势竞争的被动触摸观察器把横向滑动交回队列，系统 pager 的 pan 不处理该次手势；键控以屏幕显示位置为准，与已提交位置分离，目录、书签等外部导航后重新对齐。落页提交只对精确目标使用较短的稳定采样，邻页与回位仍保持更严采样；预热正常结束时影子导航器已停在目标页，只有上一轮落点不明或本次补了另一侧时才显式回位。首个 Locator 未到达时，两个空缓存键不能视为已就绪；准备因瞬时布局键变化而取消后按当前缓存状态重新调度，即使布局键已回到原值，也不能丢失最后一次唤醒；准备完成也不能中途禁用正在识别的冷手势。基础准备末尾不再复位影子导航器，后续预热先比对当前位置、只按需回位。长按选字优先；朗读会话期间停用卷页预取，停止后恢复。纸面延伸到全屏，正文和控件仍避让安全区，既有进度与同步格式不变，不修改上游源码。

预取导航器的根视图用空图层遮罩隔离屏幕合成，避免底色和文字透过真实 WebView 的透明区域露出；公共 WebKit 快照仍直接捕获正文内容。系统卷页创建时先放入不可见占位页，首次快照未完成时也不能让 pageCurl 容器为空，否则旋转会触发 UIKit 断言。

相关UI验证复用独立合成TXT和替代服务：`python3 scripts/test_native_pagecurl_ui.py --device <UDID> --app <独立验证Novelia.app>`，覆盖设置切换、实际落页、跨章正反返回、控件隐藏、长按选字与旋转；偏好与排版/Readium隔离由 `ReaderSettingsTests` 检查。Readium 使用 `scripts/test_readium_pagecurl_ui.py` 的三章编号 EPUB 验证，覆盖取消、首次预取中旋转、跨章往返、设置与选字、重开恢复，以及不等待准备完成的首次点按和连续输入；慢速反向夹具只在独立Debug App注入等待，确保未准备方向能被第一次反向操作提升准备；准备场景检查精确与共享进度没有被预取写入。横屏视觉证据用整屏截图，避免 XCTest 的应用区域截图在旋转后发生裁切。性能场景记录从开始卷页到再次就绪的内部耗时（包含系统动画及真实落页），并检查预热后的连续翻页不再重复进入前台准备；耗时与快照计数仅存在于独立 Debug 验证探针。开书专项从模型开始打开计时，分别记录真实正文通过布局/呈现屏障、预取导航器创建、首方向就绪、两侧准备完成，断言预取不早于正文呈现且首方向先于两侧；这些时间是明确就绪条件，不等同于真机屏幕首像素或触摸延迟。

Yuedu 分页的页面身份是 `(generation, spineIndex, pageIndex)`。拖动预览和落页必须使用同一份排版结果与位图；翻页动画只移动已有位图，不在落页时重新计算目标页。字号、视口等排版参数变化会使旧 generation 失效；拖动/吸附期间缓存新输入并延后应用，避免视图刷新重置翻页位置。

点击先判断链接与注脚命中，再判断翻页。保持跨章预取、渐进排版、任务失效与取消，缓存保留可见页及有限邻页；内存警告时收缩缓存，不能随预取无限累计位图。布局协调器合并相同请求并缓存结果，修改缓存键时纳入实际影响排版的参数。

`EPUBContainer` 负责 ZIP、OPF、spine 和目录及资源读取。CSS/图片相对引用按章节文件目录解析，目录链接按 nav/NCX 文档位置解析；不要把所有相对路径都拼到 OPF 所在目录。Yuedu 的 `linkHit` 对普通链接也检查：以 `#` 开头且命中本章 `footnotes`（引擎 `collectFootnotes` 收集的多看 `li` 或 epub:type 注释正文）时按注释弹层，否则同章锚点跳转不定位，点击会毫无反应。Readium 在章节资源映射阶段由 `EPUBReadiumImageLayout.normalizingSVGAttributes` 修正 SVG 的 `viewbox`／`preserveaspectratio` 大小写，恢复 XHTML 中的缩放语义；只改 SVG 起始标签的属性名，保留属性值、脚本、注释及原始文件，固定版式也适用此属性修正。`EPUBImageTests` 按 `application/xhtml+xml` 加载合成封面，检查修正前裁切与修正后手机／平板横竖尺寸下的图像边界。Readium 对可重排 EPUB 在资源映射阶段注入 `EPUBReadiumImageLayout`：将直接位于 `body` 下的独立 `img` 设为块元素，避免连续行内插图与孤行保护组合导致跨栏切图；段落内图片和固定版式不适用此规则。对于直接位于 `body` 下、或作为 `body > div` 唯一子元素的 SVG，使用显式 SVG 命名空间选择器补齐等比例自动尺寸、媒体宽高上限与禁止跨栏规则；避免 ReadiumCSS 的 XHTML 默认命名空间导致 SVG 媒体保护失效。沿用 `--RS__maxMediaWidth`／`--RS__maxMediaHeight`，缺省为 `100%`／`95vh`，段落内 SVG 不受此规则影响。原书不改写。此处理独立于禁用书内脚本设置。Readium 默认执行书内脚本；`SettingsKey.readerEPUBDisablesScripts` 开启时，`openPublication` 经 `onCreatePublication` 包装容器，按 `EPUBScriptRemoval` 去掉章节文档的 `<script>` 与 `on…=` 事件属性、把 `.js` 资源置空（无法按 UTF-8 解码的文档保留原文），并在 `<head>` 注入样式隐藏 `epub:type` 为 footnote／note 的弹出式脚注正文（尾注与多看章末列表不隐藏；元素仍在文档中，弹层照常读取正文），不影响 Readium 自身注入的脚本，也不改原文件。Readium 只对 `epub:type="noteref"` 链接调用注释回调；其他带锚点的书内链接经 `shouldNavigateToLink` 先拦下，读取目标文档，由 `EPUBFootnoteTarget` 按 YueduCoreText `collectFootnotes` 的同一规则（class 含 footnote 的 `<li>`，或 `epub:type` 为 footnote／endnote／note／rearnote）判断，命中则弹层，否则照常 `go(to:)`。目录按先序展平并带 `level`：nav 以外层带链接的 `<li>` 计层级（无链接的分组标题不计），NCX 嵌套 navPoint 的父项先于子项输出；`TOCOutline` 负责目录面板的分组折叠，Yuedu 与 Readium 共用 `ReaderTOCRow`，打开目录时只展开当前章节所在分组。

Yuedu 重排开始时会把位置归零并换成空分页结果，`pendingRelayoutAnchor` 记住要回到的章内偏移；重排被下一次取消时沿用该锚点，成功或非取消失败后清除。进入后台后系统会以浅色/深色及其他尺寸截取快照，阅读视图在 `scenePhase == .background` 时忽略外观与尺寸变化，回到前台再按实际值同步一次；Readium 同样不在后台重建导航器。修改重排或生命周期处理时，验证切到其他 App 再返回仍停在原页。资源查找保留已有的编码和路径回退，CSS 导入保留递归上限。

Yuedu 路径有宿主级兼容处理：剥离脚本、按设备条件处理媒体查询、转换带 alpha 的十六进制颜色、改写文字透明度、以颜色近似 text-shadow、把 `position: absolute/fixed/sticky` 降级为普通流（引擎遇到这类定位会整章拒绝排版，降级后内容按文档顺序显示，`positionRewriteCount` 计入目录诊断）。相关计数和限制不能静默消失；这些处理不代表完整浏览器 CSS 支持，也不能直接套到 Readium 路径。`EPUBPageBook.applyEngineWorkarounds` 的极小字距是排版权宜处理；调整或移除时运行对齐、宽度与字符相关回归及整书扫描，不依据旧报告的测试结果作决定。

目录诊断和内容诊断验证资源读取、解码与目录补全，不证明 WebKit 排版、脚本执行或图片/字体显示正确。需要变更引擎、依赖或兼容处理时，同时检查本地 EPUB、TXT、在线内容以及实际交互。

阅读器依赖与代码来源见 [依赖说明](iOSApp/Features/Reader/EPUBReader/DEPENDENCIES.md)，完整许可见 [第三方许可索引](iOSApp/Resources/ThirdPartyLicenses/INDEX.md)。

## 网络小说 EPUB 章节同步与更新

本节统一说明网络小说 EPUB 的更新事务、章节身份、映射、管理面板和下载配置。用户操作见[功能说明 → EPUB 下载](docs/FEATURES.md#epub-下载)。

### 手动更新事务

书库本机网络小说 EPUB 的菜单通过 `WebNovelDownloadStore.updateEPUB` 沿用旧记录的模式／译源重新请求整本文件；文件生成请求忽略本机 HTTP 缓存并要求重新验证。相同字节保留原文件与时间，新内容在提交时比较原记录，避免删除／移动竞态导致复活；失败与取消清理新文件，成功才移除旧文件。更新不更改 WebDAV 协议和按需下载规则。

App 在 Root 注入包含原下载记录的 `WebNovelEPUBUpdate.prepare`。先验证新容器和 spine，再按明确的小说身份及旧文件哈希迁移已确认章节状态，成功后 Store 才提交替换；旧文件损坏时允许更新有效新文件。迁移保留原时间和旧哈希记录，提交失败可能留下无文件引用的 ID 状态，不表示文件已替换。网站 `episodeN.xhtml` 是序号，不能作为稳定章节 ID，不再调用路径匹配推断身份。`EPUBUpdateState` 仅保留历史辅助测试，不是当前网络小说的更新迁移路径。

真实 Store 的成功、同内容、请求／校验／写盘失败、取消和删除竞态由 `test_library_transactions.py` 覆盖；路径映射、目标较新状态保护、旧版较新状态与删除合并由 `EPUBUpdateStateTests` 覆盖；隔离 App 的菜单确认流程由 `testManualWebNovelEPUBUpdate` 覆盖。源码／生成书籍用本地合成数据验证，真实网站与原书待验。

手动云端更新由 `WebDAVSyncStore.updateWebNovelEPUBFromCloud` 经过清单门闩调用 Core `WebDAVEPUBUpdater`；仅允许本机网络小说 EPUB，读取云端原文件并校验哈希，下载后重新读取清单，检查同一文件版本及本机原记录。不同文件只接受严格更晚的下载时间；同哈希只合并状态。先合并目标哈希的远端状态，再用 Store 的 `replaceFromSync` 调用同一校验／承接钩子及比较提交事务；文件复制后检查取消，失败清理暂存文件，远端时间保留，不自动上传结果。与普通同步共用忙碌状态与门闩，不改自动替换规则。协议替身回归覆盖准确字节、最新状态、同哈希、旧版本／并发变化、损坏／缺失 blob 和取消；真实 Store 回归覆盖远端时间、状态钩子、校验／提交失败与删除竞态，隔离 UI 覆盖菜单及缺少配置提示。


### ID 阅读状态与同步

仅 `LibraryReaderDestination` 的当前 `.webNovel` EPUB 进入 `App/Integrations/WebNovelEPUBReading.swift`；文库、导入、移动到文库的书不启用，`sourceWebNovel` 不作为启用条件。集成对象消费 `NovelCatalogService` / `NovelContentService` 和 Root 所有的下载 Store，不在引擎或页面创建具体 API。两引擎接收 `WebNovelEPUBContext`，以规范资源路径映射源站 ID；Readium readingOrder 按路径转换，不能直接套原生 spine 序号。

Core `WebNovelEPUBIdentity.swift` 定义 `webepub:<SHA256(带长度的书源/小说ID)>`、文件绑定映射、迁移与独立同步。映射由 `ReaderSettings.webEPUBMaps` 持有，使用同一注入 defaults；每个绑定带更新时间及更正删除记录，补全按路径合并，重复章节ID不解析。映射与文件SHA-256绑定，未核对不猜测。`WebNovelEPUBTOCMatcher` 以本机目录和网站目录的唯一标题对应源站ID，仅清理空白，不模糊化章号/标点；同时保留原文标题。旧下载目录可为仍存在的同一ID提供旧名，但旧新目录同名指向不同ID时拒绝自动匹配。卷名和原文卷名作为可选字段由网站目录的非章节分组传递；本机使用目录层级/分组标题。全局/卷内唯一对应先成为锚点，再在锚点区间分别计算最早与最晚可行的有序子序列，仅绑定两者相同的项；交叉锚点停用顺序推断，整段无法对应或有多种可能时不按序号猜测。多资源争同ID、多目录项共资源及已经确认的ID均不自动重分配。单标题候选超过512时回退手动，避免畸形目录产生平方级候选。核对复用/请求一次网站目录，不调用章节正文服务，只在本地检查缺章/缺译占位；正文预览仍由用户单独点击触发。旧书可预览并人工确认，取消保留已确认部分；纯缺章/缺译占位不当成有正文。

进度新增可选 `chapterID`，章内比例跨文件；本机同文件偏移和 Readium Locator 仍可辅助。已知ID不存在于本机映射时不回退另一版的索引/全书比例，提示更新/核对。原生只在明确用户定位时写 ID 进度，Readium 对翻页/拖动/导航记录写入意图，打开、恢复与偏好重建不提升时间。Store变化发布只读通知，集成层复用同步来的同哈希映射。书库网络小说显示稳定位置的章节信息，文库保持哈希位置。

迁移只处理已确认章节，保留旧记录和原时间；canonical书签UUID按原UUID与稳定小说键确定，避免与文库旧哈希记录冲突。107/108副本只有在本机保留原记录、能验证派生关系时归并，无法证明的不按位置/标题去重。墓碑优先于旧副本，手动更正可修正同历史时间的章节ID，不覆盖较新的阅读状态或复活删除。持久化失败可重试，映射确认不等于全部旧数据迁移完成。

`WebNovelEPUBIdentitySync` 在原内容同步成功后，经相同清单门闩使用 `WebDAVClient(webEPUBIdentity: true)` 访问独立 `NoveliaSync/web-epub-v1/`，只合并ID位置、书签/墓碑和文件映射。旧客户端不访问此目录；参与新同步的设备仍需全部升级。保持强条件提交与三次冲突重读，提交成功才应用远端状态，本机较新的并发修改由存储合并保留。映射变更参与自动同步指纹及触发。纯文库且无网络小说状态时不访问此目录。

末页事件仅由明确下一页操作触发：原生 Pager 拒绝用户翻页时判断最后章节已排版完成，Readium 用实际末资源及当前WebView的末页几何判断；不会在刚进入末章时遮挡正文。集成面板查询目录、计算已核验且有正文的章节差集（不计缺译/缺章占位），不完整或失败不显示精确0。更新保持模式/译源，提交前保留原状态，成功后重建容器/导航器；标题和正文均相同且两端唯一的已确认资源可沿用ID，新增/改写资源需核对。显式“继续阅读新章节”才推进位置。面板强制显示自身导航栏，避免继承阅读器隐藏栏导致无法返回。

对应验证：`WebNovelEPUBIdentityTests`、`WebNovelEPUBIdentitySyncTests`、真实Store事务及 `testNativeNetworkEPUBEndAndUpdate` / `testReadiumNetworkEPUBEndAndUpdate`。实际服务器、用户原书和真机体验与模拟器证据分别记录。

目录核对回归包括插章/重排、两侧同名、原文标题、旧目录改名/ID冲突、同资源多目录项、已有确认保护及旧JSON缺字段。独立Debug服务调用计数在两引擎的完整更新/核对/续读流程中断言正文服务调用为0；外部请求计数仍单独保留。计数诊断不进入Release。

手动核对默认只展示未绑定的正文资源，网站候选按标题/卷名及邻近锚点过滤，保持网站顺序并展示序号/卷名/前后章。未知可选择完整目录，多个候选默认不选中；确认后跳下一待确认项。并排预览仅在显式点击时请求一章，选择变化清空预览，异步结果须校验本机项、远端ID与文件hash未变化；更正已绑定章节需界面明确确认，沿用原迁移时间和墓碑规则。

候选页采用显式可搜索列表，显示导航栏并在点选后返回；目录检查task归属整个NavigationStack，不因推入/退出候选页重复查询或重置选择。手动确认流程断言预览前正文调用0，主动预览后为1。

### 更新时的本地文件对应

新旧 EPUB 比较统一由`WebNovelEPUBUpdate.prepare`，阅读器、书库网站更新和WebDAV替换均经Store既有钩子调用，阅读器不再另行继承。新文件先验证；旧确认状态先迁移，再读取两份文件全部正文资源。Core `WebNovelEPUBFileMatcher`仅接受两端唯一且标题/正文去空白相同的资源，不按路径序号猜ID；未确认旧副本也参与重复判定。新增/修订/占位正文保留未确认。继承保留来源绑定时间，目标确认/墓碑不覆盖。解析后复读App所有的映射Store，按新hash保存，不提升阅读时间；后续事务取消/冲突仅可能留下有效hash映射缓存，不替换原书。目录检查仍只查询目录，比较本身不访问网站。

核对/更新面板显示期间固定背景阅读器身份，关闭面板后才按新文件/映射重建；防止背景导航栏隐藏设置影响面板返回。显式继续阅读仍按用户操作重建并跳转。

更新面板的返回操作放在固定顶部栏，不依赖背景阅读器的系统导航栏样式。

### 管理入口与核对性能

手动入口位于书库每本书的更多操作菜单“章节同步与更新”，`LibraryBookActions.chapterUpdateBook` 经页面统一 sheet 显示 `WebNovelEPUBReader(managementOnly: true)`，直接使用管理模型和面板，不创建 `EPUBReaderHost`、排版器或统计会话。阅读器目录仅保留目录和图片，末页自动入口保留。管理模式不显示继续阅读动作，仍保留原进度。

同一不可变文件hash下的映射只由确认/验证/本地继承创建，创建时已排除缺章和缺译；load/refreshMap直接复用这些验证事实，不在check中逐章重读。目录标题索引线性建立，revision只在context变化时计算。EPUB容器准备、候选筛选、目录匹配及本机正文读取/解析使用后台任务。候选任务可取消，检查当前索引/hash后才更新，手动选择取消过期候选结果。

verifyAll仅读取未确认且有候选的本机正文，每64章applyVerified一次，避免每章编码全部映射并迁移书签。提交时复读共享Store，保护已有确认/墓碑，批次之间让出执行；取消保留已完成批次。Debug 计数用于回归检查打开时不读取正文、核对按批次保存、重开复用已有映射；生产构建排除这些计数。

### 旧下载配置确认

LocalBookRecords定义WebNovelEPUBUpdateConfiguration及DownloadedWebNovel.epubUpdateConfiguration：缺downloadMode绝不用于网站更新推断，translated/bilingual缺译源也返回nil；original有效且effectiveSource为nil。保留resolvedDownloadMode仅供旧记录显示兼容，不作为更新兜底。Store.updateEPUB在请求前校验明确配置；无配置抛configurationRequired，不设置进度或请求网络。成功替换写入所选配置；同内容仅CAS更新配置，保持路径/下载时间；失败/取消保留原记录。

书库更新确认框和管理/末页面板共用WebNovelEPUBUpdateOptionsSheet（位于DownloadsViews、LibraryMover之前）。语言缺省不预选；已有已知字段可显示，译文/双语要求译源，原文不传译源；取消仅关闭，明确提交才进入原更新事务。管理模型在同内容保存配置后复读Store，避免下次重复询问。WebDAV准确字节替换保留云端元数据，不提示生成设置。

## 书库、文件与统计实现

书库页面聚合网络小说下载记录和本地文库/导入记录。“全部／未分组／系列”默认选中全部；全部包含系列内书籍，多选和拖选使用当前分段与来源筛选后的列表；非空搜索仍覆盖整个书库。`LibraryStateStore` 管理展示与组织状态，Core 的 `LibraryOrganizer` 提供整理逻辑；它不负责远端小说请求。

`WebNovelDownloadStore` 通过 `NovelDownloadService` 下载网络小说 EPUB，并在 Application Support 的 `WebNovelDownloads/` 管理文件与 `library.json`。`WenkuLocalLibraryStore` 在 `WenkuEPUB/` 管理文库及导入文件和索引，使用 `LocalLibraryIndexWriter` 写入索引。记录类型为 `DownloadedWebNovel` 和 `LocalWenkuEPUB`，定义在 Domain。

下载接口负责把内容交付到指定目标，Store 负责本地记录和用户可见状态。修改下载/导入要检查文件成功而索引失败、取消、重复导入、封面处理、缺失文件及恢复流程。下载的 EPUB 经 `NoveliaAPIClient.acceptEPUBDownload` 检查（2xx、非空、ZIP 签名），任何失败都删除临时文件；导入的文件协调读取与复制在主线程之外执行，开始前先在目标位置建立空文件占住文件名。

同步入库接口 `restoreFromSync`、`replaceFromSync` 与 `applySyncedMetadata` 为 async throws；书籍与封面复制交给 `LocalLibraryFileCopier` 的独立文件队列（与索引 writer 定义在同一源文件），主执行域不等待大文件复制。先复制到同目录暂存文件，成功后移动提交，不覆盖已有目标，失败清理暂存文件。复制完成后重新核对同一书目的状态，避免等待期间的编辑／删除被覆盖；失败只回滚本次书目，不恢复整个旧数组。

`LocalLibraryRepository` 负责串行读取、修改快照、后台写盘和发布结果。两个书库 Store 的初始化不读取索引；Root 集成层先异步读取两个库，书库显示加载或可重试错误。只有两个 Store 的 `isReady` 都为真，聚合书库才向哈希刷新和孤立状态清理提供书目；`refreshHashes` 也显式检查 `librariesReady`，未就绪时保留已有哈希缓存与阅读状态；读取中或单库读取失败时不能拿另一库的部分列表清理阅读位置、最近打开时间或 Readium Locator。索引解码、重复记录整理及文件存在性检查在后台执行，损坏索引抛错并保留原文件，不能当成空书库继续覆盖。所有书库修改经 Repository；写入失败不发布候选快照，排队操作读取前一笔成功提交的最新数据。写盘开始前检查取消；已成功写盘时，即使随后收到取消也必须发布同一快照。

索引与文件队列分开。文件清理在索引提交后异步进行，清理失败只可能留下不可见孤立文件。跨书库移动先加载并核对源记录、提交目标库，再删除源记录；源删除失败时通过独立的未取消任务回滚目标，回滚前也核对创建的目标记录，目标在等待期间被编辑则保留其修改；回滚失败要明确提示原书与目标副本均保留。系列和最近打开时间只在两边提交成功后转移。编辑信息为异步操作，保存期间禁止重复保存和手动关闭；原封面读取、相册图片缩略图解码及 JPEG 编码放在后台。

索引采用原子写入；新增持久化行为不能让失败操作留下可见但不可打开的记录。文件来源分类、记录 ID、内容哈希和路径具有不同用途，不要混为同一身份。

AZW3／MOBI 导入在 `Downloads/DownloadsViews.swift` 的 `LibraryImportModel`：选择的文件含 Kindle 扩展名时先发布 `pendingKindleImport`，由书库页面弹出转换说明，确认后才导入；取消只跳过 Kindle 文件。转换先协调复制到临时目录，再由 `Library/KindleImport/KindleEPUBConverter` 在主线程之外写到书库目标路径（`.epub`），之后完全按 EPUB 走 `registerDownloadedFile`；记录格式仍为 `.epub`，不新增持久化字段，原文件不保留。转换器使用 `Vendor/CLibMobi`（libmobi C 源码，不含 DRM 代码，见其 README）解析、重建 KF8／MOBI 源文件并生成 OPF／NCX；`KindleMOBI6Normalizer` 用 SwiftSoup 把旧版 MOBI 的 HTML 整理成 XHTML，并在顶层 `mbp:pagebreak` 处分章；`KindleCSSMediaFlattener` 按 Kindle 视角展开 `amzn-*` 媒体查询。KF8 章节另做两项适配：libmobi 输出的不带前缀 `type="noteref"`／`<aside type="footnote">` 改回 `epub:type`（两个引擎只按它识别注释），同章链接 `partNNNNN.html#id` 改回 `#id`（原生引擎只把同文档锚点当作章内注脚）。旧版 MOBI 的 `width`／`height`／`align` 与 `<font>` 属性转为内联 CSS。测试样本中排版与注释部分由 `scripts/make_kindle_fixtures.py` 经 calibre 生成。转换输出必须确定（条目顺序与 ZIP 时间固定），书库按内容哈希去重依赖这一点；修改转换逻辑会改变之后导入文件的哈希，不影响已入库的书。DRM、KFX、Print Replica 与损坏文件在转换前识别，以 `KindleImportError` 报告。

文件选择器以外的导入入口统一走 `IncomingDocumentCoordinator`：`RootView` 的 `onOpenURL` 接收系统交来的 file URL，切到书库标签；`LibraryView` 在出现或队列变化时把 URL 交给同一个 `LibraryImportModel`，导入期间到达的下一个文件保留到本轮结束。`Info.plist` 与 `Info-Legacy.plist` 的 `CFBundleDocumentTypes` 声明 EPUB、TXT、AZW3、MOBI；TXT 使用系统 `public.plain-text`。系统通常先把文件复制到 `Documents/Inbox`，导入仍使用安全作用域读取、协调复制和内容哈希去重，AZW3／MOBI 沿用转换确认。

书库多选和系列长按菜单的“压缩分享”由 `Library/LibraryArchiveExport.swift` 的 `LibraryArchiveExporter` 实现：只读取书库中已在本机的书籍文件，用 `ReadiumZIPFoundation` 的 `Archive` 组装 zip，条目名按“序号 + 书名”生成并去掉非法路径字符，同名时追加序号；zip 写入临时目录的 `NoveliaShare/` 后交给系统分享面板。云端未下载的书没有本机文件，会跳过；全部跳过时返回“先下载”的提示。压缩不修改原书、书库索引、阅读进度或同步数据；产物是临时文件，不属于书库身份或备份内容。压缩任务在 `@MainActor` 上异步执行，再次发起时取消上一次，分享面板关闭后清除待分享状态。

通用文件哈希使用 `Support/FileContentHash.swift`。跨功能使用通用工具，不通过同步 UI 文件获取哈希方法。临时路径不写成长期书籍身份，缓存不能代替持久化事实。

| 数据类型 | 保存方式与负责者 |
|---|---|
| 界面、阅读与功能偏好 | `UserDefaults` / `@AppStorage` 与对应设置对象 |
| 阅读进度 | `ReadingPositionStore` 的 Codable 数据与 legacy 兼容读取；Readium 本机精确位置的键名由 `ReadiumLocatorKeys` 定义 |
| 书签 | `ReaderBookmarkStore`：Application Support `Bookmarks/bookmarks.json`，键为书签 ID，删除保留墓碑；创建目录、编码与原子写入成功后才发布 records，失败抛给阅读界面／同步调用方，单页批量删除一次提交；经 `ReaderSettings.bookmarks` 交给阅读器 |
| 摘录与笔记 | `ReaderAnnotationStore`：Application Support `Annotations/annotations.json`，键为标注 ID，删除保留墓碑；位置为章号、章内 UTF-16 范围、引文与前后文，渲染时经 `ReaderAnnotationResolver` 重定位；经 `ReaderSettings.annotations` 交给两种分页引擎与标注列表 |
| 书籍文件和本地索引 | Application Support 内的两个书库目录与对应 Store |
| 账号凭据 | `SessionTokenStore` 的生产 Keychain 适配 |
| 阅读统计与设备统计 | `ReadingStatisticsStore`：本机累计与同步缓存在 Application Support `ReadingStatistics/` 的 `local.json`、`devices.json`（`ReadingStatisticsFiles` 后台串行写入）；开关、设备 ID 与名称在偏好 |
| 解析、章节、排版与字数缓存 | 各缓存实现；属于可重建数据，保持容量与失效规则 |
| 云端同步状态 | WebDAV 清单、内容 blob 与独立统计数据 |

文库与导入书籍的“编辑信息”经 `WenkuLocalLibraryStore.updateMetadata` 只修改索引记录与封面文件并记下 `metadataUpdatedAt`，不改书籍文件，内容哈希及挂在其上的进度、书签、统计不变。同步时同一文件版本（`syncTimestamp` 相同）先由引擎 `mergeEditedMetadata` 按该时间套用较新的远端信息（`SyncBookLibrary.applySyncedMetadata`，下载封面 blob），再规划上传，使清单写回合并后的记录。封面下载后引擎重新比较当前记录，实际 Store 在应用前再次检查 `addedAt` 与 `metadataUpdatedAt`，仅接受同文件版本且严格较新的远端信息；复制与提交期间仍按完整快照检查，避免覆盖在途编辑。网络小说不提供编辑。删除书籍时 Store 一并删除书籍文件与封面；阅读位置按内容哈希保存，不随删除清除。`LibraryStateStore` 在每本本机书都算出哈希后清理残留：不在书库（本机与云端）的最近打开时间与 Readium 精确位置（键名统一由 `ReadiumLocatorKeys` 定义，阅读器与清理共用）立即清理，EPUB/TXT 共享位置超过 180 天未更新才清理，在线小说（web:）位置不清理；书库为空时不清理。系列归属与最近打开时间只在云端副本也删除成功后由 `LibraryStateStore.forget(keys:)` 清理（系列移出记录随同步传播），只删除本机时保留，因为同一书键可能仍以云端书籍出现。

旧版把本机累计与同步缓存保存在偏好键 `reading.statistics.v1`、`reading.statistics.devices.v1`；启动时迁移到文件，写入成功后删除偏好键。偏好与文件同时存在（降级后又升级）时按既有最大值规则合并，不丢降级期间的时长。无法解码的统计文件改名为 `.corrupt-<时间>` 保留。

阅读统计由 Core 的 `ReadingStatisticsStore` 保存并实现 `ReadingTimeRecording` 和 `ReadingStatisticsSyncing`。阅读界面的开始、检查点、结束事件经 App 计时适配传入 `ReadingActivityController`；统计界面消费同一 Store。记录开关关闭时停止计时，后台/离开阅读页的结束行为由事件桥接处理。修改计时要防止重复会话、后台计时和开启/关闭后状态不一致。

## WebDAV 同步实现

WebDAV 是独立传输能力，不使用小说 API 服务集合。`WebDAVSyncStore` 管理设置、任务与界面进度；Core 同步逻辑分为：

| 实现 | 职责 |
|---|---|
| `WebDAVManifest.swift` | 书籍、资源、进度、系列等清单模型与数据校验 |
| `WebDAVSyncPlanner.swift` | 比较本地/远端记录，生成传输和合并计划 |
| `WebDAVSyncEngine.swift` | 按计划传输文件、更新书库并写清单 |
| `WebDAVRemote.swift` | `WebDAVRemote`、HTTP 客户端、重定向约束与统计远端接口 |
| `SyncMerge.swift` | 同步数据合并规则 |
| `WebDAVCloudBooks.swift` | 云端书籍记录与封面缓存（`CloudBookStore`）、按需下载 |
| `WebDAVAutoSyncPolicy.swift` | 自动同步的触发判断、失败退避与本机状态指纹（纯计算） |
| `App/Integrations/SyncLocalStateAdapter.swift` | 连接实际进度、书签、摘录与笔记、系列、背景、标签与字体状态；`WebDAVAutoSyncTriggers` 转交前后台与书库／系列／书签／标注／标签变化 |

同步通过 `SyncBookLibrary` 读写两类书籍（包含异步 `prepareForSync` 与可抛错的 `removeFromSync`），通过 `WebDAVSyncLocalState` 访问其他本地状态。远端资源使用内容哈希引用，验证资源名和哈希后才导入。清单写入使用对应并发条件；`WebDAVSyncStore` 经 `WebDAVSyncEngine.runRetryingConcurrentChange` 在 `concurrentChange`（412）时重新读取清单、以新引擎完整重跑（最多三次），重跑安全依赖“清单写入前只追加较新书籍与按时间合并、删除与设置在写入成功后套用”，修改引擎时须保持这一顺序。手动同步传入 `verifiesBlobs`：引擎先用 `WebDAVRemote.listBlobs`（PROPFIND Depth 1）找出清单引用却不在服务器上的 blob，从已知集合中移除，使上传流程补传本机仍有的文件，并在 `WebDAVSyncRunResult` 报告补传与仍缺失的数量；列目录失败或不支持时不补传、不让同步失败。下载遇到 404 抛出 `missingBlob`，同步中缺失的封面跳过，按需下载时封面列为可选文件。成功列目录后，主文件缺失的云端书籍经 `SyncCloudCatalog.setMissingFileKeys` 记入 `CloudBookStore.missingFileKeys`（随本机缓存保存，只保留仍存在的记录），下载遇到缺失也会标记；书库据此显示“云端文件缺失”并提供从云端删除，书目不自动删除。内容同步与 `deleteFromCloud` 经同一 `WebDAVManifestWriteGate` 先到先执行，不交错读写清单；统计同步和按需下载不写清单，不经过它。阅读统计独立同步：每台设备只写 `statistics/<设备 ID>.json`（`ReadingDeviceStatisticsFile`），读取全部设备文件与旧版 `reading-statistics.json` 后按设备取最大值合并，因此不需要条件写入；不得把其他设备的时长写进本机文件，也不得再写旧版文件。设备 ID 用作文件名，须通过 `isValidDeviceID` 校验。设备 ID 由 `ReadingDeviceIdentity` 决定：以 Keychain（`ThisDeviceOnly`，经 `ReadingDeviceIDStoring` 注入）为准；偏好中有 ID 但未绑定 Keychain 视为旧版升级并沿用该 ID；偏好已绑定但 Keychain 没有，视为从备份复制，生成新 ID，并把复制来的本机记录与名称归还原设备。测试必须注入内存实现，不读写真实 Keychain。设备名称（`ReadingDeviceInfo`）随统计同步，本机名称只由本机修改。

书库删除通过 `LibraryStateStore.booksForDeletion` 与显示去重共用 `displayIdentity`，在异步操作前固定完整目标，避免只删代表记录后隐藏副本补位；未知哈希仍只按持久键处理，不跨来源、系列和格式。确认框的显示状态独立于待删除对象，收起不提前清空目标；删除期间显示阶段，防止重复提交。`scripts/test_api_architecture_ui.py --library-delete` 使用独立合成书库验证隐藏副本删除及云端失败反馈，并在 UI 后复核实际索引、书籍文件与封面（被删书及隐藏副本的封面清除、保留书的封面仍在），不能只依赖“下载／阅读”菜单判断本机是否还残留被去重隐藏的副本。

WebDAV 请求使用 `reloadIgnoringLocalCacheData` 与 `Cache-Control: no-cache, no-store`，避免清单条件写入重试及提交后的读回确认使用旧缓存。云端删除失败由 `LibraryBookActions` 合并失败书籍键，以书库底部提示提供重试；本机删除失败仍使用错误弹窗。

清单传输参考 Novelia 安卓端 `WebDavClient.kt`（`44be26d`，GPL-3.0-only）。内部将强 ETag 规范化为带引号值，拒绝弱版本、多个裸值与控制字符；只有官方 `dav.jianguoyun.com:443` 在条件头中发送裸值，请求使用 identity 编码。GET 没有强版本时，PROPFIND Depth 0 只接受确切目标、DAV 命名空间与成功属性；再用该版本重新读取正文，并用随机错误版本验证读取条件确实生效。无法证明版本可靠时抛出 `unsupportedConditions`，已有清单绝不无条件覆盖。坚果云首次创建前，在随机目标验证 MOVE 禁止覆盖、正确版本更新和拒绝旧版本覆盖，并读回确认拒绝后内容未变；正式创建 PUT UUID `.cache` 暂存，再 MOVE Overwrite:F，409 必须先读取确切目标判断是否冲突。真正缺目标才验证暂存源、尝试创建父目录、有限重试及同源绝对路径 Destination，总计最多三次 MOVE，不删目标、不降级覆盖 PUT。成功创建后读回校验正文与强版本，PUT 不回传强版本时也读回确认正文；清理只针对本次随机源／探测目标。该传输改动不改变 v1 清单及 blob 布局。

本地时表直接使用书籍 `addedAt`／`downloadedAt`，与 `deletedBooks` 比较，不另建重复导入表；同步恢复保留原时间，修改书名和阅读进度不代表重新导入。

为适应有请求频率限制的服务器，同步尽量少发请求：`WebDAVFolderCache` 记录已确认的目录，自动同步跳过 `verifyConnection`/`prepareFolders` 的请求，手动同步先清空再完整检查，任何同步失败都清空；引擎在清单与读取时内容相同时不写入；`ReadingStatisticsSyncCache` 记录已合并的设备文件版本（ETag，或修改时间与大小）、本机文件上传哈希和旧文件检查时间，只在统计套用到本机后保存，手动同步不使用；`format` 与当前格式不符时丢弃设备版本，重新读取一次全部设备文件。缓存丢失只会多发请求，不能影响合并结果。

用户可见的同步行为与合并规则见 [WebDAV 同步](docs/WEBDAV.md)。实现上必须保持以下行为，修改同步时针对相关失败点验证：

- 同步先等本地书库读取完成，读取失败不得将默认空数组上传；Store 在等待读取前占用同步状态，避免加载期间重复启动同步。本地删除提交失败向上传播，后续同步可以重试。

- 清单文件条目带可选 `size`；上传时写入，`fillMissingSizes` 只在本机同一版本且哈希一致时补齐旧条目，不产生网络请求。
- 云端删除写入 `deletedBooks`（`WebDAVDeletedBooks`）：仅保留最近三十天；`WebDAVSyncEngine` 在合并前按本轮注入的 `now` 裁剪，`remove` 在新增删除时也裁剪，精确三十天边界保留。裁剪变化经原 ETag 条件写回，即使未开启书籍同步也可随其他内容同步收敛；统计独立同步不触碰书籍清单。过期记录不再阻止离线旧设备重新上传。有效期内同步不恢复、不上传删除时间及之前的版本，本机的这类副本在清单写入成功后经 `SyncBookLibrary.removeFromSync` 删除；更新版本清除记录。`WebDAVCloudBookDeleter` 以条件写入清单（并发冲突重试三次），提交书目移除与墓碑；写入成功后对 `remove` 返回、清单中已无引用的 blob 逐个 `deleteBlob`，失败忽略。重试读取的最新清单若已无目标书目，且每个目标都有不早于本次请求的删除记录，则确认上一轮已提交，不再重复写入；仍存在的书目必须继续条件写入。清单提交与随后删除 blob 之间，另一设备重新引用同一内容不受本机串行门或清单 ETag 保护，该文件可能缺失；由手动同步的 `verifiesBlobs` 补传与 `missingFileKeys` 提示兜底。确认上一轮已提交时不再删除 blob，最多留下无用文件。
- 书籍同步不自动下载书籍文件：App 给引擎传入 `CloudBookStore`（`SyncCloudCatalog`），本机没有的书只记为云端书籍并下载 EPUB 封面，本机已有的书不被远端较新版本替换；上传不变。云端书籍在清单写入成功后才更新，记录与封面保存在 Application Support/WebDAVCloudBooks，属于可重建缓存。书库把它们并入 `LibraryBook`（`cloudFileHash` 为主文件哈希，用于阅读位置与去重），打开前经 `WebDAVSyncStore.downloadCloudBook` 用 `WebDAVCloudBookDownloader` 下载并 `restoreFromSync`。引擎不传 `cloud` 时保持下载全部文件的旧行为（测试使用）。
- 同步由用户手动触发，或在开启自动同步后由前台、背景、本机改动和网络恢复触发；两者走同一执行路径，同一时间只跑一个。是否自动执行只由 `WebDAVAutoSyncPolicy` 判断，指纹只读已有本地接口，不读文件内容；书签变化与书库／标签一样接入延迟推送。成功后只在执行前后指纹一致时确认已覆盖；在途编辑或远端合并导致状态变化时清空成功指纹，保守保留待同步状态，下次触发可补跑。统计同样使用上传前快照与合并后的本机状态比较，不能把新累计时长误记已上传。本地删除不传播到云端。
- 自动同步状态（`webdav.autoSync.state.v1`）分清单内容与阅读时长两部分，各自记录指纹、成功时间与失败退避，成功后记录时间，但指纹仅按上述确认规则更新；内容失败时不再同步统计，统计失败不影响已完成的内容同步；进入背景时用后台时间完成，到期取消，依赖“清单最后写入”保证中断安全。
- 执行失败或取消时，已传输文件不自动回滚。
- 清单在流程末尾写入；标签、系列、书签、摘录与笔记、背景和字体在清单写成功后才应用。单书简繁与文字替换以 `textProjections` 随书籍同步，按书键取较新的 `updatedAt`，只同步清单中本机 EPUB/TXT 的记录；单条记录超过编码体积上限时留在本机。摘录与笔记以 `annotations` 随书籍同步，按标注 ID 与 `updatedAt` 合并，远端记录先校验体积与范围，超出总量上限时保留最近更新。应用远端记录后调用 `ReaderSettings.applyTextProjectionRecords` 并推进 `projectionRevision`，打开的阅读器按既有重排路径更新正文；标注经 `ReaderAnnotationStore.applySynced` 写回同一实例。书签套用必须持久化成功，失败时向调用方抛错，保留待重试状态；远端已提交的清单不回滚。
- 自动同步不逐个检查远端 blob；手动同步列目录并在本机仍有文件时补传缺失 blob，列目录不受支持时不补传。

## 网络、缓存与诊断约定

当前小说/论坛传输使用共享请求策略：401 通过会话续期后有限重试，GET/HEAD 仅对指定瞬时错误及 502/503/504 有限重试。超时和写操作不能随意扩展重试，以免重复提交。API、文库文件和生成小说文件使用不同超时；新请求沿用对应策略，不在页面另写无界循环。

封面加载由 `CoverImage` 处理下采样、内存/磁盘缓存与并发去重；论坛 Markdown 缓存解析结果。修改共享缓存时保持内容身份、失效、容量、清理与取消规则，避免返回错误版本或让大图/富文本在主线程重复解析。

分享日志使用 `ShareableLogPolicy` 的事件允许清单，只导出 App 子系统的受控记录。新增诊断需同时定义可分享格式和回归；自由文本、用户书名/正文、路径、URL、账号和凭据不能直接进入分享文件。系统/框架日志与未知事件不透传，内部完整诊断的动态敏感字段继续使用私有日志标记。构建日志属于本机排障材料，不作为发布附件。

导出通过 `OSLogStore` 读取，在 iOS 上只能读到当前进程，并且实际只读回 `notice` 及以上级别；`info`／`debug` 只用于连接 Xcode 时的本机排障。需要出现在分享日志中的事件使用 Core 的 `ShareableLogger`：它写入系统日志（只有通过审查的消息标为公开），同时追加到 `DiagnosticJournal`（Application Support/Diagnostics，不备份，单文件约 1.5 MB、轮换保留一个旧文件，导出时取最近 7 天）。写入与读取都再经过 `ShareableLogPolicy` 审查。导出时，以前启动的记录来自该文件，本次启动的记录来自系统日志，两者按启动标识去重，因此 App 重启或被系统结束后仍可导出之前的记录。阅读诊断消息统一由 `ReaderDiagnosticMessage` 生成，不在调用处手写格式；新增事件时同时增加格式化函数、允许清单和 `ReaderDiagnosticMessageTests` 用例。

跳页相关诊断：
- 前后台切换与内存警告（`lifecycle`）。
- 默认引擎（`epub`）：阅读区尺寸变化、重排计划、重排落点（前后页码，以及 `offset`／`progression`／`fraction` 定位方式），以及重排以外的每次位置变化（来源 `cause`，包括普通翻页）。
- Readium（`readium`）：每次位置变化记录资源序号、章内与全书千分比，手势来源为 `tap`／`swipe`／`outerSwipe`，无法关联时为 `unattributed`。`page snapshot` 使用匿名阅读会话、导航器代次、操作编号和弱引用 WebView 序号关联轨迹，分别记录模型资源与 WebView URL 映射得到的资源、中央候选页面数量、加载/拖动状态及 `offset`／`width`／`content`（pt）；URL 仅用于内存匹配，绝不输出。章内手势直接采样手势所属 WebView；外层手势和位置回调只接受唯一覆盖阅读区中央且祖先可见的页面。`locationCallback` 只是位置回调后的采样，不代表动画或排版已停稳，旧导航器或旧操作的延迟采样丢弃。外层滑动每次记录方向和决定原因：章内重定向、真实边界放行、固定版交由原生容器处理，或方向未知、页面缺失/重叠、加载中、拖动中、归属不符、尺寸无效、重定向忙碌而取消；重定向另记完成、失败或导航器过期，防止把未处理当成正常跨章。`setupUserScripts` 记录 WebView 新建次数，资源失败只记资源序号。旧版事件格式继续允许导出历史记录。
- 「阅读样式」面板末尾的「标记问题」（`ReaderIssueMarkSection`）写入标记行；默认引擎同时记录当前位置，Readium 同时记录分页状态（`issue`），标记前的连续轨迹照常保留；标记位置不代表异常落点。

普通翻页也会记录，外层滑动额外记录判断与重定向结果；导出上限为 10000 行。修改来源名称时同步更新 `ShareableLogPolicy.positionCauses`。

## 新增、修改与删除功能

### 新增功能

1. 选择所属 Feature，页面与 Store 放在该目录，可测试逻辑放在 Core 对应 Feature。
2. 已有服务能满足时复用接口；需要新远端能力时按业务职责扩展相关协议或建立小协议，更新全部实现与测试替代实现。
3. 需要长生命周期本地状态时在 App 组装，提供必要的读写能力并注入，不在页面隐藏创建。
4. 跨功能协调由 App/Integrations 接线；入口在 App 导航/设置中配置。
5. 验证成功、失败/重试以及相关状态行为；涉及持久化时验证已有数据仍能读取。
6. 按[文档维护](#文档维护)同步更新用户文档与本文件。

例如新增小说详情能力：先判断是否属于 `NovelCatalogService`，在具体后台适配请求与返回模型，更新替代后台，再由详情 Store/页面消费该协议。不要在详情 View 内直接新增请求。

### 修改现有功能

优先改功能内部；不要通过改另一个功能私有状态来绕过边界。搜索、分页和异步加载要保持任务取消、过期结果丢弃、重试、缓存和页面返回状态；共享章节缓存保持请求合并及内容来源一致。涉及 SwiftUI 状态对象时沿用当前所有权，避免重建页面导致重复请求和状态丢失。

### 修复问题

1. 明确触发条件、预期行为和实际行为，定位问题属于页面状态、服务适配、业务算法、持久化还是阅读引擎。
2. 沿真实调用链查找根因；检查异步任务顺序、账号切换、取消、缓存身份和对象生命周期。不要用延时、反复刷新或重建全部状态掩盖问题。
3. 在负责该行为的层修复。响应映射错误修适配层，过期查询覆盖修 Store，进度转换错误修 Reader 转换；不要把补丁散落在多个页面。
4. 对能稳定复现的业务/数据问题增加有价值的回归，验证触发条件和相关边界；低影响的纯展示修正使用合适的界面检查。
5. 验证修复没有破坏已有数据、默认设置、离线/失败恢复和相关功能。日志使用已有诊断工具，不记录完整凭据或用户正文。

`@MainActor` 约束可观察状态更新，但不意味着适合在主线程执行解析、全书扫描、排版或大量文件处理。将重工作放在适当执行上下文，再发布结果；保持现有取消与并发约束，不随意增加 `@unchecked Sendable`。捕获后台任务错误并呈现可恢复状态，不把真正失败静默改成成功或空列表。

### 删除或关闭功能

分别处理页面入口、组装、任务/观察订阅、跨功能连接和测试。隐藏导航不等于停止后台行为。默认保留历史数据；清理数据或同步字段需要明确任务范围和兼容方案。

例如关闭阅读计时，可注入 `DisabledReadingTimeRecorder`；完整删除统计功能仍需清理统计页面、设置、App 组装与同步连接，不应重写阅读引擎。功能移除并非运行时自动卸载。

## 新增阅读资料边界

`ReaderSettings`拥有单书偏好和账号隔离的`OnlineChapterOfflineStore`，保持App注入的单一实例；阅读入口设置稳定书籍上下文，退出恢复默认上下文。单书偏好使用新增`reader.bookPreferences.v1`与按书布局键，不覆盖旧全局键。可缺省的`styleOverride`独立控制样式作用范围：旧记录缺字段仍沿用单书样式，新文字规则默认继承全局样式；关闭样式覆盖保留本书文字投影。入口在“阅读设置”，简繁/替换入口命名为“本书文字处理”。离线章的文件名由账号、来源、作品、章节身份哈希生成；actor串行化落盘、清理与在途任务，清理后旧代次不能写回，替代验证组装使用独立临时目录。

`ReadingTextProjection`在原始缓存之后、排版/搜索/朗读之前应用转换和非递归替换，HTML只改文本节点，不改属性、资源路径、脚本或样式。繁体方向先由系统 ICU 转换，再用随包的 `ChineseConversionTable` 修正一简对多繁（如「一干二净」「诗云」）并换成台湾常用词（软件→軟體、网络→網路）；表约 77 KB，由 `scripts/update_chinese_conversion_table.swift` 从 OpenCC `ver.1.4.2` 的 `STPhrases.txt` 与 `TWPhrases.txt` 派生，只保留白名单简化字上的选字差异和白名单内的台湾常用词，不采用 OpenCC 的古体用字或软件界面专用说法。替换规则和修正表都编译为前缀树并按投影内容缓存，避免每次重排重新排序全部规则。原生搜索使用排版源文本的UTF-16范围，Readium使用带上下文的Locator；搜索高亮与朗读高亮使用不同装饰组；临时查阅返回点只属于当前会话。滚动模式按正文块保留返回锚点。默认引擎使用 YueduCoreText 0.18.1 原生 ruby；章节被能力检查明确以 ruby 拒绝时，才用已有 SwiftSoup 把本章注音降级为「底文（读音）」。其他不支持的内容继续报告原始失败，不把所有错误当作注音问题；原文件不变，Readium 使用原书排版。

文库记录新增可缺省的父作品/卷ID字段；旧索引正常解码，下载时显式设置，恢复/替换沿用字段。`LibraryWenkuAssociationEditor`通过注入的文库服务搜索/选卷，Store事务只改关联与元数据修改时间，关联使用可缺省的独立修改时间区分旧客户端未知字段与明确解除；同步更新/解除关系，旧客户端仅编辑书名不会清除关联；用户可明确选择是否归入父作品系列，不自动检查新卷；系列菜单的“检查新卷”只查询已绑定作品的分卷ID差集，检查历史保存在`library.wenkuVolumeHistory.v1`，按账号与作品ID隔离，空目录或分卷目录类型变化不覆盖有效基准。父作品采用稳定系列ID；仅对从未有分组记录的卷自动关联，尊重用户移出/分组选择。书库状态只按实际阅读位置计算，不提供手工标记；初始化时清理已停用的手工状态存储键，不改动真实阅读进度。`LibraryDragSelectionModifier`只在长按成功后接管拖动，以起点前快照计算区间，反向和取消还原，CADisplayLink只在活动手势中驱动边缘滚动。

## 数据兼容

现有偏好键、Codable 记录、书籍身份和 WebDAV 清单是兼容契约，不是可随意整理的内部命名。尤其关注：

- `readingPositions.v1`、`web:/epub:/txt:` 进度身份及旧 TXT/在线进度兼容读取。
- 书库、下载记录、统计、缓存/安装身份、同步清单与 blob 身份。
- 各种数据各自的时间合并规则；不要假设所有相等时间都采用同一策略。
- 已保存的阅读设置、引擎选择与功能开关默认值。

更改 schema、身份或键名时，说明旧数据、缺失字段和迁移中断如何处理，并提供旧格式回归。不要因改目录或服务协议改变用户数据位置。

Readium 与 Yuedu 是 Reader 功能内部的引擎选择。两个模型使用 App 注入的同一 `ReaderSettings` 和进度链路。业务 API 改动不应顺带改变分章、布局、导航、缓存或引擎默认值。阅读引擎需求本身涉及这些行为时，增加针对性验证，覆盖对应 TXT/EPUB/在线场景，并明确真机尚未覆盖的交互和性能范围。

## 文件注册与构建配置

新增或移动源文件后检查：

1. `NoveliaIOS.xcodeproj/project.pbxproj` 的文件与 Sources 注册。新增源文件要同时放进 `Novelia` 与 `NoveliaLegacy`，除非它只属于原生分页或 Kindle 转换。
2. `Package.swift` 的 target 路径、显式 sources、exclude 与测试资源。Kindle 导入源码同时由 App 目标与包目标 `NoveliaKindle`（测试 `NoveliaKindleTests`）编译；`Vendor/CLibMobi` 是本地 Swift 包，App 工程以本地包引用，`scripts/run_package_tests.sh` 会把 `Vendor` 链接进固定的独立包测试工作区。
3. `scripts/source_layout.json` 中受脚本使用的路径，以及引用这些文件的测试/构建脚本。
4. 文档、许可资源、Debug/Release 条件编译。

路径映射目前按文件名索引，不可为不同目录的同名文件写入互相覆盖的映射；若需求确需重复文件名，应调整映射及消费脚本。不要只确认 Xcode 编译通过就断言 Package 与脚本也正确。

为兼容 Xcode 27.2，本地 CLibMobi 产品显式声明为静态库，Kindle 测试直接声明该产品依赖，避免自动生成测试产品时缺少 `clibmobi_CLibMobi.CLibMobi`。这不改变 C 源码或阅读器行为。

独立包验证工作区为 Vendor 创建实际源码副本（排除生成目录），避免 Xcode 27.2 经符号链接解析本地 C 包时生成无效测试产品依赖；应用构建仍使用原 Vendor 源码。

## 构建与验证

### 选择验证

迷你条返回通过直接订阅 `SpeechHandoffStore.$openRequest` 驱动根标签和书库导航，不依赖外层 `AppServices` 转发内部对象变化。导航身份由 `speechBookRoute` 环境传入，与正文哈希／书签键分离；在线阅读保留小说描述。书库加载完成或哈希缓存更新后重试未处理请求。新阅读器正文与引擎就绪后才消费请求：同书系统/Readium本地/云端优先移交既有合成器或播放器并改绑章节/高亮回调，不 stop/start、不重置音频时间；远程会话一并移交，保留定时截止时间。Readium 保留原 Publication 与 PublicationSpeechSynthesizer，只更换导航器、章节/锚点映射和高亮回调，取消旧导航器待执行的跟读任务；新页面按当前词范围定位，不调用合成器 start。准备阶段或引擎类型不匹配时才按瞬时句偏移/Locator 重建。空闲引擎不得释放其他会话持有的音频资源；远程会话未注册时注销不影响当前锁屏命令。此路径不改变持久化格式。

续听由播放控制器接收真实句首源偏移／正文长度，Readium 通过当前 Locator 的资源路径映射到实际章节。记录扩展为可选源偏移与 Locator JSON，旧记录缺字段时仍按章内比例恢复；Locator 仅在当前出版物对应章节有效时使用。Readium 续听先异步定位并等待导航完成，再传入明确 Locator 起播，避免导航尚未完成时朗读旧可见页。播放过程中沿用写盘节流，暂停、停止、前后台与移交时补存，空闲控制器不覆盖已保存记录。

朗读生命周期回归运行 `python3 scripts/test_speech_playback.py`：以可控平台桩运行实际 App 控制器、系统/Readium 引擎和远程会话，覆盖停止与迟到正文、跨章、旧回调、Readium 定位取消及锁屏命令路由；不会真实发声。测试组装将默认偏好与续听存储注入每次运行独立的临时 suite，退出时清理，避免跨次状态污染。入口/跟读控件接线有静态守卫。实际界面回归使用独立验证 App 的 `test_api_architecture_ui.py --only-testing TapTests/TapTests/testNativeSpeechPanelSurvivesChromeAndShowsCapabilities`（需按下文提供 `--device` 与 `--app`），检查系统 TTS 面板控件、关闭面板、顶栏隐藏/恢复后暂停状态保留以及显式停止。加 `--speech-regressions` 可同时运行原生跟读自动翻页、手动翻页挂起跟读与位置恢复、Readium 在线/TXT 可用性，以及在线/TXT 滚动跟读与拖动挂起的针对性 UI 场景。不据此声称真实发声、旧系统或后台音频通过；真实音频中断与后台仍需设备验收。

按实际风险选择验证，不要求每次文档或简单界面修改运行全部测试，也不编写只复述实现的测试。

| 改动 | 主要验证 |
|---|---|
| 文档、路径说明 | 链接、路径与现有实现一致；`git diff --check` |
| API 协议、工厂、映射 | `APIServiceTests`、`ArchitectureReplacementTests`、`test_service_consumers.py`；相关 App 编译 |
| 认证配置、桥接或账号 | `test_auth_login_bridge.py`、`test_unified_login.py`、`test_auth_refresh_queue.py` 及相关 API/实际账号联调 |
| 进度、统计、书库或同步 | 对应 Core 测试、`test_library_transactions.py`、`test_library_store.py`、`test_reading_statistics_store.py`；旧数据与合并回归 |
| 阅读器或页面调用链 | 对应 EPUB/Core 测试与相关 UI 回归；必要的真机验收 |
| 架构边界、验证组装或发布配置 | `check_architecture_boundaries.py`、独立 Debug App UI 与生产 Release 编译、`check_architecture_release.py` |
| 两个目标都会编译的 Swift、工程成员或 iOS 15 兼容封装 | `scripts/check_both_targets.sh`；发布仍走 `build_local_release.py` |
| 开源依赖、许可或分发 | `docs/BUILD.md` 发布流程、许可与隐私校验、相关构建回归 |

从仓库根目录运行 Core/EPUB 测试：

```sh
scripts/run_package_tests.sh '<可用模拟器名称或 UDID>'
python3 scripts/test_service_consumers.py
python3 scripts/check_architecture_boundaries.py
git diff --check
```

其他离线回归脚本也通过 `python3 scripts/<脚本名>.py` 执行；先读取脚本参数与前置条件。`scripts/build_local_release.py` 发布前要求架构依赖检查和以下七项离线回归通过，另以 `test_local_release.py` 每次检查打包与缓存关卡。`local_build_cache.py` 按工作区隔离固定缓存，`run_package_tests.py` 是独立测试和发布共用入口；相同完整源码、命令、环境、工具链和模拟器运行时的成功检查可在 24 小时内复用，日志摘要损坏/缺失、源码变化、失败或依赖检出修改不允许复用，筛选测试不能满足完整测试。编译与检查加文件锁；Release 始终调用 Xcode 增量构建，许可、生产排除和最终 IPA 检查每次执行。强制检查、全新构建及耗时记录见 [本机构建与分发](docs/BUILD.md#缓存复验与耗时)。

| 脚本 | 覆盖范围 |
|---|---|
| `test_forum_filters.py` | 论坛 API 与列表状态（合成响应） |
| `test_unified_login.py` | 统一登录流程（伪认证存储） |
| `test_auth_login_bridge.py` | 注入的登录桥接脚本，不连接认证服务器 |
| `test_library_store.py` | 书库展示分组、清理与后台哈希（隔离文件） |
| `test_library_transactions.py` | 真实书库 Store 的旧格式、损坏索引、失败提交、移动回滚、取消与并发文件操作（平台服务为本地适配） |
| `test_reading_statistics_store.py` | 阅读统计存储（隔离偏好） |
| `test_service_consumers.py` | 功能 Store 与章节缓存通过注入服务工作 |

涉及文件注册、服务组装或 SwiftUI 页面时，必须确认 App 目标编译，Package 测试不能替代 App 编译。

排版问题可运行 `scripts/scan_epub_layout.sh '<本地 EPUB 路径>'` 扫描对齐和边距；使用本地书籍时不将用户内容复制入仓库。包内回归使用测试夹具，性能数据与测试数量不写成固定验收结论。阅读器改动按相关风险检查跨章、双页、旋转、选字、主题背景、长书首屏和进度恢复；模拟器逻辑测试不能代替真机交互验收。

完整替代后台在 `Tests/NoveliaIOSCoreTests/ArchitectureFixtureBackend.swift`。新增协议操作时更新实现、状态/失败行为与相关替换测试，不以空结果或无操作掩盖缺失实现。独立验证组装位于 `App/Diagnostics/ArchitectureValidation.swift`，真实 App UI 脚本为 `scripts/test_api_architecture_ui.py`。

普通 App 的模拟器编译方式：

```sh
xcodebuild -project NoveliaIOS.xcodeproj -scheme Novelia \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/novelia-dev-build \
  CODE_SIGNING_ALLOWED=NO build
```

iOS 15 目标：

```sh
xcodebuild -project NoveliaIOS.xcodeproj -scheme NoveliaLegacy \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

主目标的部署版本保持 iOS 17。不要把 `NOVELIA_READIUM_ONLY` 加到 `Novelia`。

改动两个目标都会编译的源码或工程成员后，合并前在 Mac 上运行：

```sh
scripts/check_both_targets.sh
```

脚本用 `generic/platform=iOS Simulator` 和 `CODE_SIGNING_ALLOWED=NO` 依次编译 `Novelia`、`NoveliaLegacy`。前一个失败就不再编下一个，并以非 0 退出。这是日常检查，不打包 IPA。

公开候选版构建同时指定 `--public-release --public-release-tag`，确保配套源码说明指向精确候选标签；参数和分发材料见 [本机构建与分发](docs/BUILD.md)。

发布用 `scripts/build_local_release.py`。它已经对两个 scheme 做 Release 真机构建；`run` 在任一构建非 0 退出时抛错，外层写出 FAILED-DO-NOT-DISTRIBUTE 并重新抛出，不会写出 SUCCESS。手动触发的 `.github/workflows/build-ipa.yml` 同样先编译这两个 scheme，任一失败则该次工作流失败；随后分别打包和校验两个 IPA，全部成功后一起上传；复用本地发布脚本的版本、最低系统、签名与许可资源检查，同时运行两个可执行文件的 Release 排除和两个 IPA 的隐私检查。工作流产物只用于构建验证，分发仍使用本地发布脚本生成完整源码和依赖附件。

使用替代后台操作真实页面时，先构建独立验证 App，再执行 UI 脚本：

```sh
xcodebuild -project NoveliaIOS.xcodeproj -scheme Novelia \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/novelia-validation-build \
  PRODUCT_BUNDLE_IDENTIFIER=cc.novelia.ios.architecture-validation \
  CODE_SIGNING_ALLOWED=NO build

python3 scripts/test_api_architecture_ui.py \
  --device '<模拟器 UDID>' \
  --app /tmp/novelia-validation-build/Build/Products/Debug-iphonesimulator/Novelia.app
```

脚本支持 `--only-testing TapTests/TapTests/<方法名>`。`--epub-pagination` 在独立验证 App 中生成三章编号 EPUB，交替点按／滑动检查正反向跨章连续性；仅 Debug 且独立应用标识及 `-architecturePagination` 同时满足时启用 DOM 可见段落探针，无障碍树中的段落存在不代表屏幕可见。验证启动参数包括 `-architectureValidation`、`-resetArchitectureValidation`、`-architectureReadium`、`-architectureFailFirstSearch` 和 `-architectureTXT`，分别选择替代服务、清理验证数据、选择 Readium、注入首次搜索失败和生成合成 TXT。测试使用本地样例 EPUB/TXT，不读取用户书籍。

验证 App 必须保持 `#if DEBUG` 与独立标识 `cc.novelia.ios.architecture-validation`，使用内存凭据和独立数据目录。重置只能影响验证 App。生产 Release 排除验证参数、账号与运行时实现；检查方式：

```sh
python3 scripts/check_architecture_release.py '<Release Novelia.app 内的 Novelia 可执行文件>'
```

不得把合成后台作为生产失败时的数据回退。网络探针只核对 URLSession 外部请求，允许 Readium 本地服务；不要把计数为 0 解释为所有 WebKit 外部请求均已审计。模拟器、合成服务、实际服务器、真机是不同的证据范围，交付时分别说明。外部 EPUB 扫描缺少 `SCAN_EPUB` 的跳过也要说明。

## iOS 15 兼容规则

`Novelia` 与 `NoveliaLegacy` 长期共用源码、发布流程，以及同一 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。两个 IPA 只是同一构建号下的两个产品。

- 新代码默认必须能在 iOS 15 上编译。主目标的部署版本保持 iOS 17，iOS 15 目标保持 iOS 15.0。
- iOS 16/17 才有的 SwiftUI 或 UIKit API 放进 `iOSApp/Shared/IOS15Compat.swift`，或写在 `#available` 里。iOS 17 及以上仍走原来的系统控件。 分支返回不同视图类型时，需检查 Release 优化构建的可用性诊断；必要时用显式返回的 `AnyView` 隔离类型，不能只凭非优化类型检查通过。
- 只有原生分页阅读器相关代码放在 `#if !NOVELIA_READIUM_ONLY` 中。其余共享代码两个目标都编译。不要把 `NOVELIA_READIUM_ONLY` 加到 `Novelia`。
- 新增源文件时同时检查 Legacy 的 Sources。原生分页和 Kindle 转换以外的文件要加入 `NoveliaLegacy`。`scripts/check_architecture_boundaries.py` 会核对此列表。
- `ToolbarContentBuilder` 里不能写 `if`、`switch` 或 `#available`。条件放在工具栏项内部，或拆成不含条件的工具栏。
- 发布时两个 IPA 共用同一版本号和构建号。不要只给其中一个目标改 `MARKETING_VERSION` 或 `CURRENT_PROJECT_VERSION`。

## 性能基线

性能测量、合成样本、主机微基准／模拟器／实体设备的证据区别和故障验收流程统一见 [性能基线与故障验收](docs/PERFORMANCE.md)。测量时记录源码身份与环境，避免在编译期间采集性能成绩。物理设备或真实服务器未覆盖时保持待验收状态。

## 架构演进

`check_architecture_boundaries.py` 检查 Domain 不反向引用 UI／App／具体 API、Infrastructure 不引用界面组装、Feature 不直接引用具体 API、阅读器不引用同步 UI／具体统计 Store，并核对两个 App 目标的部署版本、`NOVELIA_READIUM_ONLY` 和被排除的源文件。它是忽略注释与普通字符串的窄范围静态守卫，不替代 Swift 编译和实际替代服务测试。两个目标仍编译同一套源文件，没有拆成多个 Swift Package。

架构注释使用中文。关键类型说明职责、实例所有者、依赖与需要保留的兼容行为；复杂流程说明原因和边界。注释应描述实际实现，避免重复类型名、逐行翻译普通代码或写入当次工作成果。调整实现时同步更新相关注释，许可证原文与工具指令保持原样。

本约定维护边界，也允许真实需求推动演进。新需求超出已有协议时，先确认职责和消费方，再选择扩展或增加接口。不要为简单页面建立空泛抽象，不预先设计无人使用的插件框架，不因目录隔离不足就顺手拆成多个 Package。

如果确需改变依赖方向、生命周期、协议或兼容契约，交付必须包含：调整原因、受影响消费方、数据兼容方案、更新后的实现/替代服务、对应验证及文档。对超出用户任务范围的重大产品或数据决策先澄清；正常接口扩展与接线在已授权范围内直接完成。

## 文档维护

仓库文档只保留当前功能、实现约束、开发与验证方法。工作计划、实施过程、任务日志和历史验收记录不写入仓库，也不在仓库内另建归档目录；需要追溯的过程记录保存在仓库外的任务系统中，逐版变更写在 GitHub Release。

功能、行为、构建或依赖改变时，在同一次改动中更新对应文档，不留到发布时补写。每项内容只在一处详细描述，其他位置用链接指向它，不复制正文。

| 改动 | 需要更新的文档 |
|---|---|
| 新增或改变用户可见功能、入口、默认值 | `docs/FEATURES.md` 对应章节（新模块同时加入目录）；属于主要能力时更新 README「亮点」表 |
| 新增、解除或改变限制 | `docs/FEATURES.md`「已知限制」；影响大多数用户时同步 README「已知限制」摘要 |
| WebDAV 同步内容、合并规则或服务器文件 | `docs/WEBDAV.md`；实现约束写在本文件「WebDAV 同步实现」 |
| 构建脚本、发布流程、分发材料 | `docs/BUILD.md`；验证命令写在本文件「构建与验证」 |
| 新增、升级或移除依赖，许可材料变化 | `docs/LICENSES.md`、`iOSApp/Resources/ThirdPartyLicenses/INDEX.md`；阅读器依赖另更新 `DEPENDENCIES.md` |
| 架构、接口、数据格式、兼容契约、验证方式 | 本文件对应章节；入口规则变化时更新 `AGENTS.md` |
| 最低系统版本、许可证、项目定位 | README 徽章与介绍，以及上表涉及的文档 |

编写约定：

- README 保持简短首页，只写介绍、亮点、下载与安装、限制摘要、致谢、许可和反馈；细节放进 `docs/`。
- 逐版变更写在 GitHub Release，不写进 README 或 `docs/`；文档描述当前行为，不写当次工作成果或测试数量。
- 使用简体中文和 GitHub 可直接渲染的 Markdown（表格、`<details>`、`> [!NOTE]` 等提示框、相对链接）；不依赖外部脚本或自定义样式。
- 公开文档不放真实账号、令牌、私人书籍或用户提供的真实论坛帖子链接。
- 许可声明与版权文字保持原样，修改须有明确任务。
- 尚未验证的行为不写成已验证；真机或真实服务器未覆盖的范围写入限制。
- 移动或重命名标题时检查指向它的锚点链接；交付前确认相对链接有效并运行 `git diff --check`。
- 仅修改文档不增加 App 版本号或构建号（见 `VERSIONING.md`）。

## 交付前检查

提交或交付前逐项确认：

- [ ] 功能代码是否消费协议，是否出现具体客户端、固定 API 地址或生产回退？
- [ ] 状态实例是否来自正确所有者，跨功能连接是否位于 App 适配层？
- [ ] 是否保持数据、会话与引擎契约；改变时是否有明确迁移及验证？
- [ ] 文件注册、脚本路径与替代实现是否同步，相关验证是否通过？两个目标都会编译的改动是否符合[iOS 15 兼容规则](#ios-15-兼容规则)，并在 Mac 上跑过 `scripts/check_both_targets.sh`？
- [ ] 是否引入新开源代码/依赖，许可、声明和对应源码要求是否满足？
- [ ] 用户可见行为、构建或依赖变化是否已按[文档维护](#文档维护)更新 README、`docs/` 与本文件？
- [ ] 交付是否写明实际执行的验证、跳过与待验收范围，避免引用旧验证代替当前检查？

## 许可

项目使用 GPL-3.0-only，第三方组件各自遵循许可；现有 YueduCoreText 的 MPL-2.0 和 Readium 等许可材料不能移除或重新授权。提交和分发按 `docs/BUILD.md` 与 `VERSIONING.md` 执行，IPA 分发需配套对应源码及许可材料。架构工作不自动授权改版本、提交、推送或发布。

跨页听书条由每个标签页导航容器的底部 `safeAreaInset` 承载，保留系统标签栏的点击区域并为正文预留高度；不要叠加到整个 `TabView` 的底部，以免在直板 iPhone 上遮挡底部导航。

原生分页在 `EPUBPageBook` 绘制显示列表时按同一近白阈值透明化填充色，保留边框、圆角、变换、彩色底与图片；跟随文字色的列表标记不处理。不改变源文档、排版缓存或源字符位置。背景规则由视图注入模型，新绘制代次保存规则快照，规则变化重建位图；选择其他规则保留原始填充。

朗读只保留本地自动路由与Edge。`SpeechSettingsStore` 初始化时删除退役自备服务的旧地址/模型/音色键，并将旧引擎选择迁移为本地，保留语速、音量、Edge同意状态等其他偏好。生产组装通过 `RetiredSpeechServiceCleanup` 精确删除旧服务/账户的Keychain项，不读取密钥、不影响账号凭据；独立验证组装不操作真实Keychain。客户端与配置入口均已移除，不再实例化自备服务。


## 本地剩余阅读时间

`ReaderSettings` 持有唯一 `ReadingTimeEstimateStore`，使用注入的 UserDefaults 保存显示／学习／手动速度设置和有界速率窗口，不依赖统计 Store 或同步实现。Core 的 `ReadingTimeMetrics` 按实际资源顺序累计字数，TXT 使用与分页一致的 36000 UTF-8 字节切分并保留逻辑章边界；`ReadingSpeedSampler` 用单调时钟，只接受前台自然前进的合理区间，每次无效区间重新建锚。每档最多 31 个速度，至少 5 个后用中位数；单书优先、语言与模式通用档兜底，档位最多 128 个。不保存原文、轨迹或历史时间戳。

`ReaderRemainingTime.swift` 是共享 iOS 15 展示层，底栏常驻采样视图不随顶栏显隐销毁。`LocalReadingTimeSource` 只接受本地 EPUB 容器或已有 TXT，后台任务取消向内传播；Readium readingOrder 必须唯一映射至 ZIP spine，不通过 Publication 额外请求正文。没有完整字数或可用速度时明确提示，不把缺失章节当零字。布局、文字规则、前后台、弹层与听书切换会重建锚点。

`SpeechPlaybackController.onProgressSave` 随真实收听续听点节流通知宿主，强制补存沿用暂停／停止／退出／后台路径。该回调与跟读开关独立；各本地宿主把实际章号、偏移／比例映射至既有进度存储，TXT 仍经过目录身份检查。滚动听书只有逻辑章号，同一章沿用 `movingToChapter`，不清除已有分页单元和偏移；换章后才丢弃旧单元。Readium 本地 Locator 同步写入本机恢复键，未提供 Locator 时由较新的通用位置恢复。听书暂停默读速度学习。`ReadingTimeEstimateTests` 覆盖逻辑章、无效位置、采样过滤、速率窗口与存储隔离；`scripts/test_speech_playback.py` 的真实控制器桩测试覆盖关闭跟读仍保存进度和重复补存去重。


## AI 阅读辅助基础设施

`AppServices.readingAI` 持有唯一 `ReadingAIStore`；生产由 `novelia` 入口组装 `OpenAIReadingClient` 与 `ReadingAIKeychain`。替代组装默认使用实例内 `MemoryReadingAIKeys` 和明确抛错的 `UnavailableReadingAIClient`，不访问生产密钥或网络。页面只消费 Store，具体 HTTP 编码与传输留在 Infrastructure/API。Domain 的 `ReadingAICompleting` 接收单次指令和明确输入，没有书库、未来章节加载器或对话历史；后续回顾／人物功能必须在调用前完成范围裁剪与用户发送意图确认。

配置由 `ReadingAIConfiguration` 验证，存储键 `reader.ai.configuration.v1` 只含非密钥字段。`requestFormat` 决定协议：`chat_completions`（缺省，旧配置没有该键时也是它）、`responses`、`anthropic_messages`。默认格式编码时省略该键，避免只升级应用就改变回顾和人物检查点的配置指纹；选了另外两种格式才会写入。未知取值解码失败，不能把旧配置悄悄改去别的协议。密钥服务名为 `cc.novelia.ios.reading-ai.v1`，账户为规范化最终接口 URL 的 SHA-256；使用 `WhenUnlockedThisDeviceOnly`，不打开 Keychain 同步，不复用账号或已退役朗读服务的身份。换基础地址或请求格式都会换成另一个最终 URL，不携带旧密钥，保存失败不切换当前配置。

客户端使用独占 ephemeral URLSession，拒绝重定向，关闭 Cookie／缓存／凭据存储；输入 128 KiB，返回按 AsyncBytes 增量接收，退出时取消底层 Session。三种格式都发 `stream: true`，按 `text/event-stream` 解析各自的 SSE；服务端改回整段 JSON 时按 Content-Type 回退。基础地址只接受 HTTPS，拒绝用户信息、查询和片段，并且不能已经以 `/chat/completions`、`/responses` 或 `/messages` 结尾。然后按格式追加对应路径：对话补全仍是 `/chat/completions` 并用 `Authorization: Bearer`；Responses 追加 `/responses`，同样用 Bearer，正文是 `instructions`＋`input`＋`max_output_tokens`，并固定 `store: false`（官方默认会把回复留在服务端）；Anthropic Messages 追加 `/messages`，使用 `x-api-key` 和 `anthropic-version`（当前为文档示例里的 `2026-10-21`），不用 Bearer，正文是 `system`＋一条 user `messages`＋必填的 `max_tokens`。

不能一一对应的开关不发送。对话补全仍由用户选择 `max_completion_tokens` 或 `max_tokens`，JSON 用 `response_format.type=json_object`；“关闭思考”发送兼容接口的 `thinking.type=disabled`，低／中／高／最高发送 `reasoning_effort`。OpenAI 名称以 o 开头的推理模型（例如 o1、o3、o4-mini）和 Gemini 认的是 `reasoning_effort`，官方 Chat Completions 不认单独的 thinking 开关。Responses 把“关闭思考”映射为官方 `reasoning.effort=none`（部分模型会 400），其余档位用同名 effort；JSON 用 `text.format.type=json_object`，不代填 `json_schema`。`max_output_tokens` 按官方说明包含可见正文和推理 token。Anthropic 的低／中／高／最高写入 `output_config.effort`（没有 xhigh 这一档）；`thinking.type=disabled` 在不少当前模型上会 400，因此“关闭思考”不可选也不发送。Anthropic 的 JSON 只能是带 schema 的 `json_schema`，本应用没有可发送的 schema，所以该开关在此格式下关闭；提示词仍可要求 JSON，由回顾和人物卡校验。两种新格式都不把思考／推理摘要当成结果正文。Responses 与 Anthropic 流式回复必须收到完成状态才作为生成成功保存；提前断流的正文仅供临时预览，明确报错，不提交为完整回顾或人物资料。

1 MiB 上限约束的是**拼装后的正文**（或整段 JSON 响应），流式原始字节另有 16 MiB 防护：逐 token 推送时每个事件都带 JSON 外壳，用正文上限去卡原始流会让长输出反而先失败。非流式回退路径仍保留 300 秒等待新数据、600 秒整体的超时：默认 60 秒会把一段 4096–8192 tokens 的正常输出直接掐断。请求限时且无自动重试，不记录头、正文、密钥和原始服务端错误。Store 为每个请求持有可取消任务与独立进度，汇总字数只计算正在运行的请求；结束或取消即清理，并以请求存活状态和配置代次拒绝迟到回调。对话补全的非流式结果只接受 `finish_reason=stop` 的非空文本，截断、拒答和工具调用分别拒绝；它的流式结果仍只拒绝 `length` 和 `content_filter`，这是原有行为。Responses 以 `status=completed` 为成功，`incomplete_details.reason=max_output_tokens` 为截断，`content_filter` 或 `refusal` 内容为拒答，`function_call` 等非 message／reasoning 输出为无效。Anthropic 以 `stop_reason` 为 `end_turn` 或 `stop_sequence` 为成功，`max_tokens` 为截断，`refusal` 为拒答，`tool_use` 和 `pause_turn` 为无效。流式事件里的服务端 `error` 只变成无效结果，不把错误正文带回界面。输出 tokens 参数和 JSON 模式显式配置，JSON 结果的业务结构与事实出处由后续功能校验。

`ReadingAIInfrastructureTests` 使用内存凭据、假生成服务和 URLProtocol 内存响应，覆盖请求隔离、三种格式的路径／请求头／正文、SSE 与整段 JSON、大小／状态／返回结构、密钥作用域、取消及配置损坏恢复；不连接真实模型，也不使用真实密钥。连接测试只发送固定短句，JSON 模式使用对应 JSON 指令，AI 总开关关闭时也可由用户显式测试。Mac 验证仍运行 Package 测试与两个 scheme 编译；真实服务兼容、费用和 Keychain 设备行为需另行验证。设置页里的示例地址用 `Text(verbatim:)` 显示，避免 SwiftUI 把字符串字面量当 Markdown 后把 `https` 示例点开。


## AI 前情回顾

`ReaderSettings.recaps` 持有唯一 `ReadingRecapStore`，保存按书哈希隔离的最后实际阅读时间、提示间隔和最多 32 本的有界结果缓存，独立于统计／WebDAV。`ReaderRecapPresentation` 在本次打开的新日期写入前判断提示，前台正文连续可读 15 秒才更新日期。提示默认 7 天，只在ReadingAIStore的isReadyForGeneration为真（已启用、配置有效、当前接口存在非空可读取密钥）时认领；检查前刷新凭据状态，缺API或密钥不弹提示。实例内 30 分钟认领窗口避免引擎切换重建视图重复提示，第一章或 AI 关闭不自动询问；不从旧进度时间戳推断阅读间隔。

`LocalRecapSource` 只接收已有 TXT 或本地 EPUB。原生／Readium 的 TXT 分页均用 `TextChapterSource.tocEntry` 把单元转为逻辑章；EPUB 按目录 spine 起点分组，Readium 当前资源必须唯一映射至包内 spine。读取闭包在创建时绑定当前章上界，范围越界直接拒绝；使用独立 ZIP 容器，不调用在线内容服务，不导航主阅读器。ZIP 条目消费回调通过加锁缓冲区累计正文，大小校验与追加在同一临界区完成，避免跨执行器共享可变局部变量。`PagedTextBook.localRecapBook` 仅本地 TXT 提供，在线正文不提供此能力。

Core 的 `ReadingRecapPlan` 要求输入为边界之前连续 1–3 章，正文总预算 96 KiB，按字符安全分块且最多 12 次顺序请求。`ReadingRecapGenerator` 每块发送前后核对配置，取消或任何块失败都不交付部分结果。模型只返回结构化事件，每条的章号、连续引文和源 UTF-16 偏移均校验；汇总不再引入第二次自由生成，去重后保留最多五件最近事件。校验限制证据边界，不等同语义正确率保证。

缓存键包含文件／目录／文字投影身份、实际正文哈希、当前边界、模型配置（不含启停开关）和提示词版本；从缓存恢复仍按本次正文与偏移重新验证。出处在独立只读页定位引文，不调用阅读位置／统计写入。`ReadingRecapTests` 覆盖未来章节排除、Unicode 分块、伪引文、异常偏移、预算拒绝、日期、回退缓存隔离与假模型生成；网络和 Keychain 回归沿用 AI 基础设施测试。


## 跨卷人物词条

`ReaderSettings.characters` 持有唯一 `CharacterLexiconStore`，以稳定系列 ID 作为作品身份，单独保存用户确认的书籍键卷序及人物 UUID。`CharacterFact` 独立携带显示名称、正文版本、卷章、UTF-16 引文范围、原文和手工修订状态；人物没有独立的全局真名／简介，`CharacterScope.visible` 在逐事实过滤后才派生名称、别名、首次记录与查询匹配，避免未来字段混入已知人物。卷序变化后原资料保留，并用新序列和当前章重新筛选。

人物自动化由 `CharacterSeriesView` 提供“仅本书／系列所有书籍”和生成／更新入口。确认卷序后，`CharacterScope.readBoundaries` 按每卷真实保存位置限制范围，当前书内入口优先使用实际位置；缺失卷、无进度卷和后卷排除，不默认前卷读完。每次按钮操作先刷新本地状态；当前阅读位置不等同逐章读完记录，跳读空缺不能识别。

`CharacterAutomaticUpdater` 逐章调用 `CharacterExtractionPlan`，单章最多2 MiB、256块，每块8000字节并重叠200字符。**扫描采用建档模式**：每人只要一条 40 字以内的身份事实，输出量约为逐人详写的四分之一到三分之一；细节由 `CharacterDetailUpdater` 在人物详情页按需补，复用 `detailRequest` 与同一套逐条核验，再通过 `append` 追加到现有卡片，不推进扫描检查点。空章直接推进检查点，不发请求；`CharacterExtractionPlan.isNonContent` 判定不足350字的封面、版权页、作者简介、目录与分卷标题页同样只记检查点，避免把作者／译者当作角色并浪费请求。单章必须在本轮请求预算内才开始。默认每轮64次新请求，可选择32/64/128/256，缓存命中不计费请求。

取正文按批一次调用 `LocalRecapSource.load`：EPUB 的读取闭包每次调用都会重算整本 SHA-256 并重新解包，逐章调用会让本地解包串行排在网络请求前面。

提取与落盘拆成 `extract` / `apply` 两步：并发时按批同时请求多章（1／2／3，默认 2），落盘仍严格按章序串行提交，检查点不会因为后完成的章节而跳过前面的失败章；每次返回结果后立即提交连续成功的前置章节，不等待整批结束；后章先完成时暂存，遇到失败章停止推进。请求额度用带锁的计数器在后台线程扣减，避免并发下超额。同名重复卡由 `CharacterLexiconStore.duplicates` 分组、用户在“校准重复人物”里确认合并，不自动合并。

`CharacterLexiconStore.reset(scope:)` 重建本作品：删除人物、逐书检查点与图片，并把“已否决”整表清空，让用户删过的条目重新参与提取；`localChanges` 里否决记录改为整表赋值而非并集，否则它永远无法被撤销。提取缓存键以「作品ID|正文摘要」开头，重建时只清本作品的缓存。

人物与 `CharacterScanCheckpoint` 同一档案事务保存，单章全部成功才推进位置；取消或失败保留此前完整章节。可选 `scans`/`rejected` 字段兼容旧v1档案，未知/损坏档案仍停止写入。检查点签名包含正文投影身份、卷序、模型参数和自动化提示词代次，变化后重新处理；回退不删除进度，但展示始终重新按阅读边界过滤。

`validate` 逐条核验而不是整块核验：引文不在本块原文、章号越界、或缺少可核验人名证据时只丢弃该条事实，其余候选照常保留——一个8000字节分块通常有十余人，整块作废会让真实角色随一条不合格引文一起消失。只有整块一条都没通过、而模型确实返回了候选时才抛 `evidence` 中止本章，防止把没扫成功的章节记成已完成；此前会先原样重发一次该块（多消耗一次请求额度），失败结果不进缓存。`candidate_id` 在本次 `known` 中匹配不到同名候选时按独立候选保存，不合并任何既有资料。候选与事实字段按可选解码，缺字段只丢弃该条，不让整块 JSON 解析失败。分块请求按每条事实约220 tokens 估算上限（最多64条，8192 时约37条），默认输出上限4096；上限受服务端能力约束（DeepSeek 最高8192），输出被截断会让整块 JSON 不可解析，这是同一条链路上唯一无法逐条挽救的失败。

跨批上下文来自 App 注入的同一人物Store，严格过滤到当前处理块之前，只带稳定ID、名字、最近60字符提示，最多12人/约3000字节；待核实事实不作为后续提示。不同称谓不自行合并，同名但未返回明确已知ID的候选保持独立。新候选ID包含版本、卷、块、条目、人名及引文，避免模型重排名称后与旧人物错误复用ID。`CharacterNameEvidence` 的可选书籍和版本字段支持跨卷人名证据，旧档案缺字段视为同卷；读取出处时分别核验两个来源，不写主阅读位置。

模型的uncertain、代词关联、同名歧义和非经历类别的潜在变化标记为待核实，自动保存但不进入确定概览；无疑点的新事实按ID增量追加，不覆盖旧事实。人物概览仅用本地分组，无额外概括模型请求。确认、合并和拆分仍保留出处；删除同时保存有界证据指纹，模型更换后重扫同版本正文也不重新加入被否决的同一证据，不保存被删除描述全文。归档上限16 MiB/2000人物/20000事实，损坏或未知版本保留原数据并停止写入。人物、确认卷序、否决证据、图片和完整章节检查点参与WebDAV；请求缓存、临时分块、API配置与密钥不参与。

`CharacterExtractionCache` 缓存已核验块的结构化响应，最多256项/2 MiB，不含密钥；键包含正文身份、卷、模型参数、提示词和请求上下文，命中仍复验证据。失败重试复用完整成功块，不自动重试网络。阶段性缓存可保留未完成章的成功分块，但不将其展示为已完成卡片。

`CharacterVolumeLoader` 连接书库文件、分章与进度，使用只读副本，不调用会迁移位置的 `ReaderSettings.txtBook`，不激活另一套单书设置。界面预检仅保留版本与边界；生成时逐卷打开、逐章释放正文，不同时常驻整个系列。运行任务、令牌、进度和步骤记录由 ReaderSettings 持有的同一 CharacterLexiconStore 按作品管理；页面退出不取消，重进可观察和暂停已有任务，同一作品不重复启动扫描。切换范围、配置或显式暂停取消生成并丢弃迟到结果。UI回归 `test_api_architecture_ui.py --only-testing TapTests/TapTests/testCharacterScopeChoiceAndUnreadSafety` 在独立验证App内使用合成TXT检查范围按钮和无已读章节保护，不调用真实AI；自动入库、增量更新与跨卷证据由Core合成测试覆盖。

`ReadingCharactersEntry` 负责阅读器到明确系列的导航适配，使用书库键或唯一文件哈希匹配，不按书名猜测。`ReaderRecapPresentation` 提供查询环境动作；原生选字菜单与 Readium 编辑动作传入人名，TXT 滚动使用普通菜单查询。查询不触发 AI。出处单独读取本地章节，核验版本和引文；安全同名章节回退仍检查当前进度，不导航主阅读器、不计阅读时长。

`CharacterLexiconTests` 覆盖回退时隐藏身份与别名查询、缺失／变更卷、跨作品隔离、伪引文及越界章、同名不合并、显式合并后防剧透、拆分／修订证据保留、卷序确认和损坏存储保护。真机的选字、导航、旧系统和真实模型质量必须独立验证；静态语法与工程登记不能替代双 scheme 编译。

### 人物图片与同步

`CharacterPortraitCodec` 在后台用ImageIO缩略解码并重新编码JPEG，源文件最多20 MiB，输出最长边1024像素/1 MiB，丢弃原图元数据。相册复用iOS15兼容选择器，文件入口持有安全作用域直到读取完成。图片以SHA-256命名存入App容器的CharacterPortraits，图片总目录限64 MiB；Store接收注入目录，测试使用独立临时目录。显示按保存图片时的书籍版本和阅读边界过滤。合并优先目标图片，空目标承接源图片；拆分不复制；移除以同步墓碑表示，已无引用的本地图片在事务提交后清理。

人物同步使用 `NoveliaSync/characters-v1/index.json` 和独立blobs，复用WebDAVRemote的强ETag/条件写入、命名空间隔离及最多3次冲突重读。`CharacterSyncState` 逐事实记录数据、所属人物/作品和修改时间，删除保留墓碑；同一事实在合并/拆分中移动归属而不丢出处。不同事实并集，同ID较新修改胜出，同时间删除优先并确定性决胜。确认卷序与图片逐记录合并；相同检查点签名取较大nextChapter，不同签名按记录版本选择且本机必须重新核对签名，不能用新版本的进度跳过旧版本。

`CharacterLexiconStore.commit` 将资料、同步记录与检查点原子保存，旧归档缺sync字段迁移为逐事实记录并修复重复事实ID；损坏原档停止写入。网络期间的本机修改在applyCharacters时再次合并，不用请求开始时的快照覆盖实时状态。资料限20000条、同步事实（含墓碑）限40000条、远端状态限8 MiB、本机归档（含同步元数据）限16 MiB；达到上限明确失败，不截断墓碑。否决指纹跨设备合并，被否决的同版本证据不重新进入人物表。

图片先上传，条件提交成功后才合并人物元数据；下载逐张校验大小/哈希，取消或失败清理无引用暂存图片。缺图不丢弃人物卡，手动同步核对并从本机副本补传；失效图片记录显示占位。元数据删除成功后尽力清理远端无引用图片，失败不复活记录。人物改动与检查点进入自动同步指纹并通过App适配触发延迟同步；扫描缓存不进入指纹。App使用同一人物Store，独立Debug验证App仅使用合成TXT/合成图片/内存凭据；新验证参数和种子代码必须在Release排除检查中拒绝。

人物详情补充按最多三个来源卷章分卷执行，支持暂停；成功核验回复复用有界提取缓存，缓存命中仍重新核验。部分请求失败会明确报告错误，已经保存的事实保留，不把失败显示为没有新细节。

阅读菜单的“查看人物卡”直接展示本作品已保存的各卷人物资料，无需确认卷序或重新生成；无资料时显示空状态，进入人物详情后仍可编辑已有资料。浏览范围采用已存资料的实际章节上界，禁止将整数最大值等内部哨兵显示为章号。“更新人物卡”保留范围选择与生成操作。

人物资料生成以“阅读助手”对话面板展示：用户范围请求、真实章节处理事件、运行状态及结果摘要按顺序呈现；支持暂停、继续更新、查看人物卡和关闭自动跟随。原始回复片段折叠在运行详情中。仅展示最近一轮内存记录，不新增模型请求或自由聊天接口。

阅读助手同时流式展示 AI 实际回复：结构化人物提取中已完整收到的人名和描述直接投影为消息，保留原文，不额外概括；未闭合字段等待后续数据，原始回复可展开。已接收回复不代表事实已核验。按本轮会话隔离，完成及暂停后仍可查看；最多16条/4 MiB，仅内存保留，退出进程即清空，不进入日志、偏好或同步。
