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
- [书库、文件与统计实现](#书库文件与统计实现)
- [WebDAV 同步实现](#webdav-同步实现)
- [网络、缓存与诊断约定](#网络缓存与诊断约定)
- [新增、修改与删除功能](#新增修改与删除功能)
- [数据兼容](#数据兼容)
- [文件注册与构建配置](#文件注册与构建配置)
- [构建与验证](#构建与验证)
- [架构演进](#架构演进)
- [交付前检查](#交付前检查)
- [许可](#许可)

## 项目概览

Novelia 是面向 iOS 17 及以上系统的第三方小说客户端，使用 Swift、SwiftUI 和 UIKit。主要能力包括网络小说和文库发现、收藏与历史、论坛、本地 TXT/EPUB 书库、在线阅读、EPUB 下载、阅读统计和手动 WebDAV 同步。

界面使用 SwiftUI，阅读器按引擎需要结合原生视图和 WebKit。可观察状态通常由 `@MainActor` Store 管理；远端操作使用异步服务接口；Core 保存业务模型、算法和存储逻辑。项目没有统一采用单一大型 ViewModel，每个功能应沿用适合其职责的现有实现。

API 实现在开发时通过组装替换。项目采用服务协议、统一组装、功能目录和跨功能适配；没有用户书源系统或动态插件系统。

Xcode App 当前直接编译 App 与 Core 源文件，功能目录并不是独立编译模块。Swift Package 为 Core 与 EPUB 提供测试目标；不要假设编译器已经阻止所有跨目录依赖。

## 开始开发

开发环境：macOS 上的 Xcode（当前在 Xcode 27.0 上维护）、iOS 17 或更高版本的模拟器，以及用于离线回归与发布脚本的 Python 3。App 编译与测试命令见[构建与验证](#构建与验证)。

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

## 启动、导航和状态生命周期

`NoveliaApp` 是 `@main` 入口，用 `@StateObject` 持有 `AppServices`。正常启动通过 `AppServices.novelia(configuration:)` 创建配置、账号与服务集合，再交给 `RootView`。Debug 启动可选择独立验证组装。

`RootView` 构建底栏和各栏的 `NavigationStack`。底栏顺序、启动页和上次选择由 `AppTabLayout` 与设置键控制；默认入口为书库、发现、社区和我的。修改导航时同时考虑用户保存的底栏配置和页面返回状态。

实例所有权分为两类：

- `AppServices` 持有配置、API 集合、小说账号、论坛账号和 `LocalAppServices`；后者持有进度、阅读设置、统计、计时控制器、书库状态与同步。
- `RootView` 持有并注入收藏、历史、远端文库、网络小说下载和本地文库/导入书库 Store。需要 API 的 Store 在初始化时接收对应服务。

Root 还连接账号恢复、续期注册、账号变化后的收藏刷新、前台恢复与更新检查。把新的启动行为放在正确生命周期中，防止视图重建重复启动任务。页面内的查询状态由页面自己的状态对象持有；共享持久化状态不能随页面销毁而重新创建。

## 功能实现地图

下表路径除特别标明外均相对 `iOSApp/Features/`。

| 功能 | 主要入口与实现 | 状态与职责 |
|---|---|---|
| 账号 | `Account/AccountAuth.swift` | 登录桥接、统一会话、Keychain 凭据适配与账号状态 |
| 发现与详情 | `Discover/DiscoverViews.swift`、`DiscoverStore.swift`、`NovelDetailViews.swift` | 搜索、排行、标签、分页、详情和评论；调用目录/评论等服务 |
| 书库 | `Library/LibraryViews.swift`、`LibraryStore.swift`、`LibraryComponents.swift` | 聚合本地记录、查询筛选、系列、排序与展示状态 |
| 收藏与历史 | `Library/FavoritesStore.swift`、`ReadingHistoryStore.swift`、`ShelfViews.swift` | 账号相关远端状态、收藏操作、历史与续读 |
| 文库 | `Wenku/WenkuStore.swift`、`WenkuViews.swift` | 远端文库查询、详情和收藏；本地文件另由书库 Store 管理 |
| 下载与导入 | `Downloads/WebNovelDownloadStore.swift`、`Library/WenkuLocalLibraryStore.swift` | 下载、导入、文件位置、记录写入及同步书籍接口 |
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
手动同步 → WebDAVSyncStore → 计划与引擎 → 远端接口 + 本地状态接口
```

社区使用 `ForumStore` 持有列表/分类/查询状态，帖子、评论和编辑页面消费 `ForumService`。Core 的 `ForumMarkdown.swift` 提供 Markdown 相关处理与链接路由，界面层负责渲染、展开剧透等交互。修改富文本或链接时保留配置来源检查、相对链接处理与内部导航，不在渲染组件中建立另一套 API 请求。

设置通过 `SettingsKeys.swift` 中的已有键及对应状态对象保存偏好。背景、字体、标签和分章规则有各自的存储/适配；设置界面负责用户操作，阅读器负责消费结果，同步通过 App 适配获取可同步部分。新增设置时明确默认值、已保存值、立即生效范围和是否同步。

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

### 替换 API 的步骤

1. 如果仅地址改变且 API/认证格式兼容，使用 `APIConfiguration` 和当前工厂；网页来源、评论来源与认证入口也必须一致配置。
2. 如果格式或语义改变，在 Infrastructure 中实现需要的服务协议，将响应转换成 Domain 模型。请求字段、分页换算和服务错误处理留在适配层。
3. 在 App 组装处显式构造完整 `APIServiceCollection`。可有意组合多个实现，但不得在缺失能力、请求失败或开发配置错误时偷偷退回生产客户端。
4. 认证协议不同则实现相应认证适配。当前 API 协议仍含 providerId、novelId、分页等站点语义，不能承诺任意后端只换地址就兼容。
5. 用替代服务验证消费方，再对实际服务器进行鉴权、分页、下载和失败恢复联调。

禁止在 Feature 中创建 `NoveliaAPIClient`/`ForumAPIClient`、拼接固定站点 API 地址或发临时 HTTP 请求绕过协议。站点链接路由应使用已有配置与路由逻辑。WebDAV 和发布更新有各自传输职责；不要把所有网络行为硬塞进小说 API 协议。

### 认证不可随意改变的约定

小说与论坛是同一个用户账号，但分别维护 `app=n` 与 `app=f` 会话。书籍评论虽然使用论坛来源，仍使用小说会话。改变这些对应关系必须有后端证据及相关回归。

生产账号状态、API token provider 与续期入口使用同一 `SessionTokenStore`。生产适配继续使用原 Keychain/Vault；测试使用内存适配。不要在消费方直接读取 Vault、解析 JWT 判断账号，使用 `AccountSessionProviding` 的状态和 `matchesAccount`。

保留登录桥接的 HTTPS、主框架、来源 host/port 检查、配置校验、受控 JS 数据编码及有界续期/重试。不为测试放宽生产检查，不把真实 token、Cookie 或密码写入代码、日志、测试、文档或记忆库。

## 本地状态与跨功能连接

`LocalAppServices` 创建并持有进度、阅读设置、阅读统计、计时控制器、书库状态和 WebDAV 同步实例。Root 注入观察对象，阅读器、书库和同步必须使用同一套实例。

不得恢复 `ReaderSettings.shared`、`LibraryStateStore.shared`、`ReadingStatisticsStore.shared`，不得在子页面创建第二套生产状态。测试可使用隔离 `UserDefaults` 构造独立服务；阅读设置与进度应使用相同的注入存储。

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

项目仍保留部分解析、布局、图片缓存和背景、标签、规则等共享服务；这不代表新增持久化功能可以继续引入全局单例。修改现有共享服务时核对生命周期、并发与状态隔离，避免为一次小需求全面重写。

## 阅读器实现

阅读内容与排版引擎分开处理。在线内容通过 `NovelContentService` 获取，本地 TXT 由 Core 的 `TXTChapterParser` 和 `TXTBookCache` 处理；EPUB 由 `EPUBContainer` 读取容器、章节和资源。不要把下载或网站认证逻辑放进排版模型。

| 实现 | 主要职责 |
|---|---|
| `ReaderView.swift` | 在线滚动阅读、正文/译文选择，以及在线分页入口和章节缓存 |
| `TXTReaderView.swift` | 本地 TXT 阅读入口、目录和滚动/分页模式连接 |
| `EPUBChapterSource.swift` | 章节内容接口、文本转 XHTML、长章节拆分与 TXT 分页定位转换 |
| `EPUBContainer.swift` | EPUB 内容与资源读取，提供章节来源能力 |
| `EPUBPageBook.swift`、`EPUBLayoutCoordinator.swift` | Yuedu 分页内容、布局协调和缓存 |
| `EPUBReaderModel.swift`、`EPUBReaderView.swift`、`EPUBPagerView.swift` | 原生分页模型、显示与翻页交互 |
| `ReadiumTextPublication.swift` | 将 TXT/在线文本章节包装为 Readium Publication，并提供导航索引 |
| `ReadiumEPUBReaderModel.swift`、`ReadiumEPUBReaderView.swift` | Readium 内容加载、导航、显示和位置连接 |
| `ReaderSettings.swift`、`ReaderSettingsAdapters.swift` | 持久化阅读偏好及引擎/界面适配 |

EPUB 默认采用 YueduCoreText 分页；实验性 Readium 开关可用于 EPUB、TXT 和在线分页，开关默认关闭，已有选择继续保留。TXT 和在线内容也支持滚动模式。引擎选择属于 Reader 内部，API 消费方不根据引擎切换后台实现。

在线章节缓存需要保持相同请求的合并、成功内容复用和失败后的重试。长 TXT/章节采用拆分与导航索引，修改时关注首屏耗时、索引构建次数和内存，避免每次翻页重复扫描全书。

阅读位置有内容身份与引擎位置两个层次。持久化模型位于 Domain，进度由 `ReadingPositionStore` 管理；TXT 分页单元、EPUB spine/offset 和 Readium locator 的转换留在阅读实现。改变拆分策略或 locator 映射时检查旧进度、字号变化、旋转、目录跳转和引擎切换后的定位。

### 文本分页与按需加载

`TextChapterSource` 将 TXT 或在线内容转为经过转义的 XHTML 段落，供章节接口消费。TXT 长章节拆为分页单元，仅章节起始单元进入目录；不要把 XHTML 标签长度当成源文本偏移。拆分和定位同时涉及 UTF-8、UTF-16 与章节索引，修改时验证 emoji、组合字符、卷标题、无标题全文和分章规则变化。

`ReadiumTextPublication` 直接把惰性单元包装成 Publication 的 readingOrder，通过 Resource 按需生成内容，不临时打包 EPUB，不提前获取全书正文。生成的 TXT/在线书籍不执行 EPUB 全书资源诊断。位置服务为每个单元提供一个位置，位置数不是实际页数；显示整书比例时还需结合单元内 progression。

在线阅读沿用原文、译文、双语及译源选择，保留段落顺序、次要文字样式与缺译提示。进度、书签和服务端历史仍为章节级；显示模式或译源改变时从该章开头恢复，不能把一份译文的字符偏移直接套用到其他正文。正文 HTTP/HTTPS 链接通过既有打开方式处理，EPUB 包内链接另行解析。

Resource 每次请求重新创建，避免将一次加载失败固化为缓存结果。重试可以重建 Readium 导航器并恢复失败位置；章节请求、位置换算和预取保持取消检查，不能让旧请求覆盖当前章节，也不能为翻页阻塞主线程。

### 进度恢复与设置兼容

TXT 的共享位置使用 `txt:<内容哈希>`，保存章节、单元、偏移及单元数。`TXTReadingPosition.pagedStart(in:)` 在单元数量仍匹配时恢复分页位置，否则回退章节起点；同章节滚动位置更新保留分页信息，跨章节后清除失效的单元位置。保留旧 `txtReadingPosition.v1.<hash>` 的读取兼容。

TXT 的 Readium 精确 Locator 使用内容哈希和分章规则指纹作为身份。仅当 Locator 时间不早于共享进度、且资源属于当前单元时优先使用；否则由共享单元/偏移换算为章内比例。打开恢复不刷新同步时间戳；翻页后的异步偏移换算只应用于仍有效的当前位置。跨引擎、跨设备恢复是近似位置，不能承诺落在完全相同的页面。

EPUB 本机 Readium Locator 与共享 spine/章内比例分别保存；共享进度较新时按其恢复。Yuedu 使用源文本偏移，旧记录仍可按整书比例回退。不同来源的时间判断和偏移规则以各实现为准，不为了统一模型而删除兼容字段。

共享字号范围为 12–36。读取时优先全局字号，缺失时读取旧 EPUB 样式，再回退默认值；仅读取不写入迁移，调整字号时更新原全局键与旧样式中的字号并保留其他字段。外观、背景、`readerPagedText`、`readerEPUBReadium` 和 `epubPrototype.*` 等键继续兼容。EPUB 专属行段间距、缩进、边距、字体和双页设置留在已有样式对象。

### 原生分页、缓存与资源边界

Yuedu 分页的页面身份是 `(generation, spineIndex, pageIndex)`。拖动预览和落页必须使用同一份排版结果与位图；翻页动画只移动已有位图，不在落页时重新计算目标页。字号、视口等排版参数变化会使旧 generation 失效；拖动/吸附期间缓存新输入并延后应用，避免视图刷新重置翻页位置。

点击先判断链接与注脚命中，再判断翻页。保持跨章预取、渐进排版、任务失效与取消，缓存保留可见页及有限邻页；内存警告时收缩缓存，不能随预取无限累计位图。布局协调器合并相同请求并缓存结果，修改缓存键时纳入实际影响排版的参数。

`EPUBContainer` 负责 ZIP、OPF、spine 和目录及资源读取。CSS/图片相对引用按章节文件目录解析，目录链接按 nav/NCX 文档位置解析；不要把所有相对路径都拼到 OPF 所在目录。资源查找保留已有的编码和路径回退，CSS 导入保留递归上限。

Yuedu 路径有宿主级兼容处理：剥离脚本、按设备条件处理媒体查询、转换带 alpha 的十六进制颜色、改写文字透明度、处理特定 table 布局、以颜色近似 text-shadow。相关计数和限制不能静默消失；这些处理不代表完整浏览器 CSS 支持，也不能直接套到 Readium 路径。`EPUBPageBook.applyEngineWorkarounds` 的极小字距是排版权宜处理；调整或移除时运行对齐、宽度与字符相关回归及整书扫描，不依据旧报告的测试结果作决定。

目录诊断和内容诊断验证资源读取、解码与目录补全，不证明 WebKit 排版、脚本执行或图片/字体显示正确。需要变更引擎、依赖或兼容处理时，同时检查本地 EPUB、TXT、在线内容以及实际交互。

阅读器依赖与代码来源见 [依赖说明](iOSApp/Features/Reader/EPUBReader/DEPENDENCIES.md)，完整许可见 [第三方许可索引](iOSApp/Resources/ThirdPartyLicenses/INDEX.md)。

## 书库、文件与统计实现

书库页面聚合网络小说下载记录和本地文库/导入记录。`LibraryStateStore` 管理展示与组织状态，Core 的 `LibraryOrganizer` 提供整理逻辑；它不负责远端小说请求。

`WebNovelDownloadStore` 通过 `NovelDownloadService` 下载网络小说 EPUB，并在 Application Support 的 `WebNovelDownloads/` 管理文件与 `library.json`。`WenkuLocalLibraryStore` 在 `WenkuEPUB/` 管理文库及导入文件和索引，使用 `LocalLibraryIndexWriter` 写入索引。记录类型为 `DownloadedWebNovel` 和 `LocalWenkuEPUB`，定义在 Domain。

下载接口负责把内容交付到指定目标，Store 负责本地记录和用户可见状态。修改下载/导入要检查文件成功而索引失败、取消、重复导入、封面处理、缺失文件及恢复流程。索引采用原子写入；新增持久化行为不能让失败操作留下可见但不可打开的记录。文件来源分类、记录 ID、内容哈希和路径具有不同用途，不要混为同一身份。

通用文件哈希使用 `Support/FileContentHash.swift`。跨功能使用通用工具，不通过同步 UI 文件获取哈希方法。临时路径不写成长期书籍身份，缓存不能代替持久化事实。

| 数据类型 | 保存方式与负责者 |
|---|---|
| 界面、阅读与功能偏好 | `UserDefaults` / `@AppStorage` 与对应设置对象 |
| 阅读进度 | `ReadingPositionStore` 的 Codable 数据与 legacy 兼容读取 |
| 书籍文件和本地索引 | Application Support 内的两个书库目录与对应 Store |
| 账号凭据 | `SessionTokenStore` 的生产 Keychain 适配 |
| 阅读统计与设备统计 | `ReadingStatisticsStore` 的本地 Codable 数据 |
| 解析、章节与排版缓存 | 各缓存实现；属于可重建数据，保持容量与失效规则 |
| 云端同步状态 | WebDAV 清单、内容 blob 与独立统计数据 |

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
| `App/Integrations/SyncLocalStateAdapter.swift` | 连接实际进度、系列、背景、标签与字体状态 |

同步通过 `SyncBookLibrary` 读写两类书籍，通过 `WebDAVSyncLocalState` 访问其他本地状态。远端资源使用内容哈希引用，验证资源名和哈希后才导入。清单写入使用对应并发条件；阅读统计独立同步并要求服务器提供 ETag，遇到并发更新应报告或按既有逻辑重试，不能无条件覆盖。

用户可见的同步行为与合并规则见 [WebDAV 同步](docs/WEBDAV.md)。实现上必须保持以下行为，修改同步时针对相关失败点验证：

- 同步只由用户手动触发；本地删除不传播到云端。
- 执行失败或取消时，已传输文件不自动回滚。
- 清单在流程末尾写入；标签、系列、背景和字体在清单写成功后才应用。
- 远端清单引用的 blob 视为已存在，不逐个询问服务器；因此服务器上被手动删除的 blob 不会自动补传。

## 网络、缓存与诊断约定

当前小说/论坛传输使用共享请求策略：401 通过会话续期后有限重试，GET/HEAD 仅对指定瞬时错误及 502/503/504 有限重试。超时和写操作不能随意扩展重试，以免重复提交。API、文库文件和生成小说文件使用不同超时；新请求沿用对应策略，不在页面另写无界循环。

封面加载由 `CoverImage` 处理下采样、内存/磁盘缓存与并发去重；论坛 Markdown 缓存解析结果。修改共享缓存时保持内容身份、失效、容量、清理与取消规则，避免返回错误版本或让大图/富文本在主线程重复解析。

分享日志使用 `ShareableLogPolicy` 的事件允许清单，只导出 App 子系统的受控记录。新增诊断需同时定义可分享格式和回归；自由文本、用户书名/正文、路径、URL、账号和凭据不能直接进入分享文件。系统/框架日志与未知事件不透传，内部完整诊断的动态敏感字段继续使用私有日志标记。构建日志属于本机排障材料，不作为发布附件。

## 新增、修改与删除功能

### 新增功能

1. 选择所属 Feature，页面与 Store 放在该目录，可测试逻辑放在 Core 对应 Feature。
2. 已有服务能满足时复用接口；需要新远端能力时按业务职责扩展相关协议或建立小协议，更新全部实现与测试替代实现。
3. 需要长生命周期本地状态时在 App 组装，提供必要的读写能力并注入，不在页面隐藏创建。
4. 跨功能协调由 App/Integrations 接线；入口在 App 导航/设置中配置。
5. 验证成功、失败/重试以及相关状态行为；涉及持久化时验证已有数据仍能读取。

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

1. `NoveliaIOS.xcodeproj/project.pbxproj` 的文件与 Sources 注册。
2. `Package.swift` 的 target 路径、显式 sources、exclude 与测试资源。
3. `scripts/source_layout.json` 中受脚本使用的路径，以及引用这些文件的测试/构建脚本。
4. 文档、许可资源、Debug/Release 条件编译。

路径映射目前按文件名索引，不可为不同目录的同名文件写入互相覆盖的映射；若需求确需重复文件名，应调整映射及消费脚本。不要只确认 Xcode 编译通过就断言 Package 与脚本也正确。

## 构建与验证

### 选择验证

按实际风险选择验证，不要求每次文档或简单界面修改运行全部测试，也不编写只复述实现的测试。

| 改动 | 主要验证 |
|---|---|
| 文档、路径说明 | 链接、路径与现有实现一致；`git diff --check` |
| API 协议、工厂、映射 | `APIServiceTests`、`ArchitectureReplacementTests`、`test_service_consumers.py`；相关 App 编译 |
| 认证配置、桥接或账号 | `test_auth_login_bridge.py`、`test_unified_login.py` 及相关 API/实际账号联调 |
| 进度、统计、书库或同步 | 对应 Core 测试、`test_library_store.py`、`test_reading_statistics_store.py`；旧数据与合并回归 |
| 阅读器或页面调用链 | 对应 EPUB/Core 测试与相关 UI 回归；必要的真机验收 |
| 架构验证组装或发布配置 | 独立 Debug App UI 与生产 Release 编译、`check_architecture_release.py` |
| 开源依赖、许可或分发 | `docs/BUILD.md` 发布流程、许可与隐私校验、相关构建回归 |

从仓库根目录运行 Core/EPUB 测试：

```sh
scripts/run_package_tests.sh '<可用模拟器名称或 UDID>'
python3 scripts/test_service_consumers.py
git diff --check
```

其他离线回归脚本也通过 `python3 scripts/<脚本名>.py` 执行；先读取脚本参数与前置条件。`scripts/build_local_release.py` 发布前固定运行以下六项离线回归，另以 `test_local_release.py` 检查打包流程：

| 脚本 | 覆盖范围 |
|---|---|
| `test_forum_filters.py` | 论坛 API 与列表状态（合成响应） |
| `test_unified_login.py` | 统一登录流程（伪认证存储） |
| `test_auth_login_bridge.py` | 注入的登录桥接脚本，不连接认证服务器 |
| `test_library_store.py` | 书库文件移动与哈希（隔离文件） |
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

脚本支持 `--only-testing TapTests/TapTests/<方法名>`。验证启动参数包括 `-architectureValidation`、`-resetArchitectureValidation`、`-architectureReadium`、`-architectureFailFirstSearch` 和 `-architectureTXT`，分别选择替代服务、清理验证数据、选择 Readium、注入首次搜索失败和生成合成 TXT。测试使用本地样例 EPUB/TXT，不读取用户书籍。

验证 App 必须保持 `#if DEBUG` 与独立标识 `cc.novelia.ios.architecture-validation`，使用内存凭据和独立数据目录。重置只能影响验证 App。生产 Release 排除验证参数、账号与运行时实现；检查方式：

```sh
python3 scripts/check_architecture_release.py '<Release Novelia.app 内的 Novelia 可执行文件>'
```

不得把合成后台作为生产失败时的数据回退。网络探针只核对 URLSession 外部请求，允许 Readium 本地服务；不要把计数为 0 解释为所有 WebKit 外部请求均已审计。模拟器、合成服务、实际服务器、真机是不同的证据范围，交付时分别说明。外部 EPUB 扫描缺少 `SCAN_EPUB` 的跳过也要说明。

## 架构演进

架构注释使用中文。关键类型说明职责、实例所有者、依赖与需要保留的兼容行为；复杂流程说明原因和边界。注释应描述实际实现，避免重复类型名、逐行翻译普通代码或写入当次工作成果。调整实现时同步更新相关注释，许可证原文与工具指令保持原样。

本约定维护边界，也允许真实需求推动演进。新需求超出已有协议时，先确认职责和消费方，再选择扩展或增加接口。不要为简单页面建立空泛抽象，不预先设计无人使用的插件框架，不因目录隔离不足就顺手拆成多个 Package。

如果确需改变依赖方向、生命周期、协议或兼容契约，交付必须包含：调整原因、受影响消费方、数据兼容方案、更新后的实现/替代服务、对应验证及文档。对超出用户任务范围的重大产品或数据决策先澄清；正常接口扩展与接线在已授权范围内直接完成。

## 交付前检查

提交或交付前逐项确认：

- [ ] 功能代码是否消费协议，是否出现具体客户端、固定 API 地址或生产回退？
- [ ] 状态实例是否来自正确所有者，跨功能连接是否位于 App 适配层？
- [ ] 是否保持数据、会话与引擎契约；改变时是否有明确迁移及验证？
- [ ] 文件注册、脚本路径与替代实现是否同步，相关验证是否通过？
- [ ] 是否引入新开源代码/依赖，许可、声明和对应源码要求是否满足？
- [ ] 交付是否写明实际执行的验证、跳过与待验收范围，避免引用旧验证代替当前检查？

## 许可

项目使用 GPL-3.0-only，第三方组件各自遵循许可；现有 YueduCoreText 的 MPL-2.0 和 Readium 等许可材料不能移除或重新授权。提交和分发按 `docs/BUILD.md` 与 `VERSIONING.md` 执行，IPA 分发需配套对应源码及许可材料。架构工作不自动授权改版本、提交、推送或发布。
