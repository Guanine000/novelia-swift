# EPUB 排版原型 · 交付报告（整合版）

> 2026-10-08 v0.5.0 后续改动：阅读页右上角改为“阅读样式”面板，提供字号、设备对本 App 可见的字体族、从“文件”导入 TTF/OTF/TTC 字体、导入字体管理与删除、恢复默认、行间距、段落间距、首行缩进以及四边边距。导入字体复制到 App 文档目录，下次启动重新注册。点击“应用”后一次性重排，偏好写入本机 UserDefaults；按当前章内页数比例近似恢复阅读位置。iPhoneOS Release 编译通过；真实 EPUB 中的字体覆盖效果和操作手感仍需真机确认。下文表格是早期 20 轮原型交付时的历史快照。

> 同版包含：阅读页底栏进度条可拖动，松手后按章及章内页定位；样式预处理增加 CSS4 `#RGBA` / `#RRGGBBAA` 转 `rgba()`，并扩展 `@media` 的 screen/all、orientation、宽高比、and/逗号组合求值。复杂 CSS 仍受 YueduCoreText 当前支持范围限制，`text-shadow` 仍是颜色近似。

- 仓库：`Guanine000/novelia-ios-port`（私密）· 分支 `prototype/yuedu-coretext-pager` → 已合并 `main`（PR #1，merge commit `679236a`）
- 报告时间：2026-10-08 · 覆盖迭代：20 轮（样例书搭建 → 4 本真实 EPUB 真机反馈修复）
- **术语约定**：本报告严格区分"模拟器实测 / 真机已验收 / 已构建待真机验收"三档，不以"已构建"冒充"已验收"。逐轮细节见 git 历史中本文件的前版（`00eb23e` 及更早）。

---

## 一、修改的文件（对照上游基点 `8e4889d`，共 14 个文件，+3035/-50）

### 新增（宿主原型，全部新写于 `iOSApp/EPUBPrototype/`）

| 文件 | 行数 | 职责 |
|---|---|---|
| `PrototypeEPUBContainer.swift` | 774 | ZIP/container.xml/OPF/spine/manifest/nav/NCX 解析；CSS 与图片装载（百分号解码、大小写回退、包内绝对路径、data: URI）；宿主级 CSS 回退（script 剥离、opacity→rgba、@media 求值、display:table 剥离、text-shadow→颜色），均带计数披露 |
| `PrototypePageBook.swift` | 190 | 页面标识与缓存（generation×spine×page）、逐页增量排版（页间 yield + 渐进发布）、位图渲染、链接/注脚命中 |
| `PrototypeReaderModel.swift` | 463 | 阅读状态、代次失效、跨章预取、导入、链接导航、主题（深浅色）、进度计算、错误可读化 |
| `PrototypeReaderView.swift` | 377 | 全屏阅读页、覆盖式工具栏、目录（当前进度定位高亮）、注脚弹层、底部进度条+百分比、文件选择器 |
| `PrototypePagerView.swift` | 297 | 左右相接、跟手平移翻页；时序守卫（拖动/动画中不重放内容）；点击命中优先于翻页 |
| `PrototypeSampleBook.swift` | 193 | 可复现样例 EPUB 生成器（仅调试启动参数使用） |
| `DEPENDENCIES.md` | 38 | 依赖版本/许可证/分发义务（MPL-2.0 NOTICE 要求） |

### 修改

- `NoveliaApp.swift`：`NoveliaStyle` 四色改动态（跟随系统深浅色）；调试入口改 `fullScreenCover`
- `LibraryViews.swift`：我的下载导入入口（点击直开选择器）、13+1 处白色卡片背景改动态色
- `WenkuViews.swift`：3 处白色卡片背景改动态色
- `iOSApp/Info.plist`（新增）：EPUB 类型注册（`UTImportedTypeDeclarations` + `CFBundleDocumentTypes`）
- `NoveliaIOS.xcodeproj/project.pbxproj` + `Package.resolved`：SPM 依赖锁定与 Info.plist 接线
- `EPUB_READER_REPORT.md`：本报告

### 依赖（未修改任何上游源码）

YueduCoreText 0.8.0（SPM 精确锁定，MPL-2.0）、ReadiumZIPFoundation 3.0.1（MIT）、SwiftSoup 2.13.7（传递）。上游修改文件 = 0。

## 二、核心不变量

PageID 三元组唯一确定一份排版结果；拖动预览、吸附动画、落页显示引用同一份 PageFragments→DisplayList→位图；翻页动画零重排零重渲染；字号/视口/主题变化 → generation+1 整组失效；逐页增量排版让首页立即可用。

## 三、问题与根因（20 轮汇总）

| # | 问题（真机反馈） | 根因 | 修复 | 提交 |
|---|---|---|---|---|
| 1 | 样例书脚注/注脚链接弹"暂不支持" | 引擎 LinkInteractionRegionSet 含 noteref 语义，宿主未接 | 注脚命中→弹窗；普通链接先提示后导航 | 首轮系列 |
| 2 | 真实书报 `HTMLLayoutError 错误 1` 且不可读 | catch 直接显示 localizedDescription；资源装载盲区 | 错误映射（unsupported/resourceFailure 点名）；资源查找加固 | `312a58a` |
| 3 | 缺 `../Images/i-000a.jpg` | 相对 href 拼到 OPF 目录而非**章节文件目录** | CSS/图片相对章节目录解析 | `9db453a` |
| 4 | `scripted-interactive` 报错；找不到导入入口 | 章节内嵌 `<script>`；导入入口不直观 | script 剥离（目录页披露数量）；"我的下载"导入入口 | `d423df5` |
| 5 | 翻页卡顿/无预览；目录点不动 | 整章排版阻塞主线程；nav href 基准目录错误（mapped=0） | 逐页增量排版+yield；相邻页预渲染分离；nav/NCX 相对其文档目录解析（mapped=10/10） | `7a06f77` |
| 6 | 透明度不生效 | 引擎不支持 opacity 属性但支持 rgba alpha | `opacity:X`→`color:rgba(主题色,X)`，数量披露 | `ac0c856` |
| 7 | 导入文件选不了；阅读器呈浮窗 | 动态 UTI 未注册一致性；调试通道走 sheet | 选择器改 `.data`→后改 UIDocumentPicker；EPUB UTI 正式注册；调试入口 fullScreenCover | `8479e70`→`b5aa815` |
| 8 | 右上角应直开导入 | 菜单二级结构冗余 | 按钮直开选择器，菜单移除 | `f3fbc36` |
| 9 | 主页无深色适配 | NoveliaStyle 四色硬编码浅色 | 四色改动态（UIColor dynamicProvider） | `af61df1` |
| 10 | 发现页白底白字 | 卡片容器硬编码 `.background(.white)` | 13+1 处改动态 card 色 | `c45a729` |
| 11 | 文库页同问题 | WenkuViews.swift 另有 3 处硬编码白底 | 同法修复，全项目白色卡片清零 | `d048440` |
| 12 | 《终末停滞委员会 5》只能翻 6 页 | 多看风格插图页（display:table+table-cell+vertical-align:middle）令图片在布局阶段被整体丢弃→连续空白页 | 剥离该组合（消元实验定位；插图改顶对齐），数量披露 | `0c452ba` |
| 13 | 台词白字不可读 | 书设定白字+彩色 text-shadow 描边；引擎不支持阴影 | 带颜色的 text-shadow→`color:<阴影色>`（角色配色保留） | `ca47348` |
| 14 | 功能请求：目录定位、进度条 | — | 目录高亮+滚动到当前条目；底部进度条+百分比+常驻细线 | `445d0c5` |
| 15 | 功能请求：深色模式 | — | 阅读器与全 App 跟随系统深浅色，opacity 换算跟随主题 | `9201a3d` |

## 四、各验收项实测结果

| 验收项 | 状态 | 依据 |
|---|---|---|
| 容器解析（ZIP/OPF/spine/nav/NCX） | ✅ 模拟器实测 | 4 本真实 EPUB 全部解析成功（27/48/33 章）；目录映射日志 10/10 |
| 封面/插图渲染 | ✅ 模拟器实测 | 3 本书封面 + 插图页（illus3/illus4）截图确认 |
| ruby 注音 | ✅ 模拟器实测 | 《1/n》"Blokus"注"角斗士棋"上方、《终末》日文注音正确 |
| 文字透明度（opacity） | ✅ 模拟器实测 | 日文原文浅灰/中文黑色（浅色）；深色下暗白（跟随主题） |
| text-shadow 台词 | ✅ 模拟器实测 | 白字→阴影色文字，同位置同内容对照 |
| 目录当前进度定位/进度条 | ✅ 模拟器实测（静态截图） | 高亮+28% 显示正确；滚动动画未逐帧验收 |
| 深色模式（阅读器+主页） | ✅ 模拟器实测（静态截图） | 阅读器第 12 章深色、书架页深色 |
| 跨章连续翻页 | ⏳ 已构建待真机验收 | 增量排版+预渲染已实现；拖动手感/闪动未定量验收 |
| 目录跳转动作（点击→落章） | ⏳ 已构建待真机验收 | 映射与导航代码就绪；用户未回报修复后结果 |
| 书内链接跳转 | ⏳ 已构建待真机验收 | 同上（含 CONTENTS 页条目） |
| 注脚点击弹窗 | ⏳ 已构建待真机验收 | 标记可见（截图）；点击交互 simctl 无法模拟 |
| EPUB 导入（选择器选文件） | ⏳ 已构建待真机验收 | copy 模式选择器+UTI 注册；此前 open 模式与 fileImporter 均真机失败，新版未回报 |
| 真机整体手感（拖动跟手度等） | ⏳ 已构建待真机验收 | — |

## 五、所用 EPUB 类型（全部真实书籍，非合成）

1. **《どうせ、この夏は終わる》**（27 章）：首个真实样本，暴露资源装载盲区
2. **《１／ｎのワトソン》双语对照译本**（48 章，Novelia 产出）：每章内嵌 kobo.js 脚本、opacity 50–124 处（日文原文标记）、ruby 36–98 处、章节在 `OEBPS/Text/` 子目录、nav 带锚点
3. **《玩乐关系 4》译本**（39 章，Kindle 风格）：CSS 含 5 个 @media 块（amzn-mobi/print/device-aspect-ratio）
4. **《这里是，终末停滞委员会。5》**（33 章，多看风格）：display:table 插图页、char-quote 白字+text-shadow 台词、duokan-footnote 脚注、bonus 章

覆盖的特性谱系：XHTML 1.1、外链/内联 CSS、ruby、多看/Kindle 私有约定、图片章节、脚注、双语段落、深色适配需求。

## 六、仍存在的问题与已知限制

1. **text-shadow 本身仍不支持**：现以"阴影色作文字色"近似；引擎升级后可移除回退。
2. **同章锚点不精确定位**：目录/书内链接跳到目标章首页，不落到锚点（需引擎 source-offset 支持）。
3. **@media 求值保守**：未知查询一律丢弃（基础样式保留），复杂条件媒体查询可能失真。
4. **8 位 hex（#RRGGBBAA）不支持**：引擎 parseColor 边界，遇到时颜色声明被忽略。
5. **工具栏遮首行**：覆盖式工具栏可见时，正文首行标题被半透明顶栏遮一部分（可加固定内边距解决）。
6. **进度为近似值**：spine 粒度 + 章内页进度；未排版章节按均匀权重估计。
7. **主题切换需重排**：深浅色切换触发 generation 重排（设计使然，动画期间冻结）。
8. **导入选择器真机未确认**：copy 模式 + UTI 注册版待复验；若仍失败，兜底方案为应用内自实现文件浏览。

## 七、提交、推送与构建状态

- **Git**：`prototype/yuedu-coretext-pager` @ `00eb23e` 与远程同步；PR #1 已合并 `main`（`679236a`）；工作树干净；仓库私密。
- **构建**：每轮 Debug（模拟器验证用）与 Release（IPA）均 `BUILD SUCCEEDED` 后才打包。注意：21:05 曾因 `~/.swiftpm/security` 权限拦截产生一版含旧代码的 IPA（SHA `fef6720a…`），已作废重打。
- **最新 IPA**：`build/Novelia-unsigned-prototype.ipa` · 7,144,206 bytes · SHA-256 `c748008fe7473c2e4e9289a0f49afba20f25ff0fa70baf14affbd71bea665e6d`（含至第 20 轮全部修复，未签名，需自行签名侧载）
- **调试通道**：`-prototypeBookPath <文件>` 直开任意 EPUB；`-prototypeJumpSpine <n>` 自动跳章；引擎诊断日志（`config.onDiagnostic`）与容器日志（`epubcontainer`）常开。

## 八、真机复验清单（下次安装最新 IPA 后）

导入（选择器点选文件）→ 连续拖动翻页 ≥10 次（预览=落页、不闪不卡）→ 目录跳转与当前进度高亮 → 书内 CONTENTS 链接 → 注脚点击弹窗 → 深浅色切换 → 《终末》第 6 页之后连续阅读。任一异常截图回报即可继续定位。
