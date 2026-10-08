# EPUB 阅读原型 · 第二轮修复报告

- 分支：`prototype/yuedu-coretext-pager`（私密仓库 `Guanine000/novelia-ios-port`）
- 本轮提交：`3b5358d`（修复轮，6 个文件）；上一轮：`2827417`（初版切片）
- 状态：**已构建、已模拟器验证；真机验收未做**。文中所有"真机待验"项目均不能视为已通过。
- 依赖：YueduCoreText **0.8.0（exact）**、ReadiumZIPFoundation 3.0.1、SwiftSoup 2.13.7（传递），见 `iOSApp/EPUBPrototype/DEPENDENCIES.md`。未复制/修改 YueduCoreText 或 Yuedu-reader 源码，未使用其品牌素材。

## 一、修改的文件

| 文件 | 变更 |
| --- | --- |
| `iOSApp/EPUBPrototype/PrototypePagerView.swift` | 翻页时序守卫（T1）、CF 安全的位图判等（修复启动崩溃）、链接/注脚命中优先于翻页（T5）、中部点击回调（T3） |
| `iOSApp/EPUBPrototype/PrototypePageBook.swift` | 每页缓存 DisplayList 与 `LinkInteractionRegionSet`、注脚文本表；命中与渲染共用同一份结果 |
| `iOSApp/EPUBPrototype/PrototypeEPUBContainer.swift` | 保存 manifest；nav/NCX 改从 manifest 定位；空目录诊断原因（T4） |
| `iOSApp/EPUBPrototype/PrototypeReaderModel.swift` | 链接命中解析（noteref→注脚文本）、注脚弹窗状态、Files 导入（security-scoped + NSFileCoordinator）、目录诊断暴露 |
| `iOSApp/EPUBPrototype/PrototypeReaderView.swift` | 全屏阅读页（覆盖式工具栏、点中部显隐）、注脚底部弹层、导入入口与失败提示、目录空诊断展示 |
| `iOSApp/LibraryViews.swift` | "我的下载"：文库/网络小说 EPUB 正文行点击推入原型（`navigationDestination`），导出改为行尾图标；菜单入口保留 |

## 二、各问题根因与修复

### 1. 翻页闪动 / 落页后偶尔跳回
- **根因（以探针日志确认时序）**：SwiftUI 任何 body 重算（`isAnimating` 切换、`isLayingOut`、落页提交等）都会重放 `updateUIView → apply(images:)`，其中 `layoutStripContent()` 无条件把 strip 归零——发生在拖动/吸附中即表现为闪动；发生在"动画结束→新内容到达"的窗口内则显示旧内容并复位，表现为跳回。
- **修复**：拖动中/吸附动画中 `apply` 只缓存不布局；三个槽位位图（`CFEqual` 判等）未变化时完全跳过；动画结束回调中先应用缓存内容保证 strip 归零且像素一致。
- **附带修复（本轮真机必崩）**：第一页 `previous == nil` 时 `CFEqual(nil, nil)` 触发 Core Foundation 断言（SIGTRAP，进程启动后约 1 秒退出）。已改为空槽位单独比较。该崩溃导致上一轮 IPA 在打开样例书时必崩，已用探针日志逐级定位确认。
- **验证**：模拟器 4 次连续启动（3 次原型 + 1 次普通）进程全部存活；探针时序显示提交窗口内的重放被正确跳过。**拖动手感与真机连续翻页待你复验。**

### 2. 无法导入 EPUB
- 阅读页顶部新增导入按钮（Files `fileImporter`），security-scoped 资源经 `NSFileCoordinator(.forUploading)` 复制到 `Documents/PrototypeImports/` 后进入同一阅读流程；失败以弹窗显示具体原因（非 ZIP/无 OPF/spine 为空等在容器解析层就有明确错误文案）。
- "我的下载"中文库 EPUB 与网络小说 EPUB 文件行点击直接进原型。
- **验证**：代码路径构建通过；fileImporter 为系统 UI，模拟器未做自动化点击。**导入真实 EPUB 待你真机验证。**

### 3. 阅读界面为浮窗
- 已改为从"我的下载"`navigationDestination` 推入的**全屏阅读页**：隐藏导航栏与 Tab 栏；顶部为覆盖式工具栏（返回 / 书名 / 导入 / 目录 / 字号），底部为页码与翻页箭头；点击正文中部显隐工具栏（参考 Yuedu-reader 的交互行为；仅参考布局与交互，未复制源码）。工具栏是覆盖层，显隐**不改变正文视口**，因此不会触发重排。
- **验证**：模拟器截图确认全屏布局与排版正常。真机交互待你复验。

### 4. 目录不显示
- **根因**：上一版只在 `spine` 中找 `properties="nav"` 的章节，而真实 EPUB 的 nav.xhtml（EPUB3）与 toc.ncx（EPUB2）通常**只在 manifest 中、不在 spine**——样例书同样中招，所以你看到目录为空。
- **修复**：从 OPF manifest 定位 nav（`properties` 含 `nav`）与 NCX（`media-type=application/x-dtbncx+xml`），解析后把目录 href 映射到 spine 序号；目录仍为空时显示可诊断原因（"manifest 中没有 nav/NCX 条目" / "nav 解析出 N 个条目但无法映射到 spine" 等）。
- **验证**：修复路径已构建通过；样例书目录项与 spine 的映射逻辑未变（此前已验证跳转可用），**真实 EPUB 的 EPUB3 nav / EPUB2 NCX 两种结构待你真机确认**。

### 5. 注释点击无弹窗、反而翻页
- **根因**：上一版点击只按左/中/右分区处理，没有链接命中。
- **修复**：排版时为每页构建 `LinkInteractionRegionSet`（YueduCoreText 官方命中 API，含 `epub:type=noteref` 语义），点击时先用页本地点命中：命中 noteref 且能找到注脚文本（`session.pipelineFootnotes`）→ 底部弹层显示注释，关闭后阅读位置不变（无翻页、无重排）；命中普通链接 → 弹提示"原型暂不支持链接跳转"（按未答复时的保守默认处理，未实现书内跳转）；未命中才进入翻页判定。
- **验证**：命中优先级在代码路径上先于翻页；**样例书两个注脚与真实 EPUB 注脚的点击弹窗待你真机确认**。

## 三、验收项状态（明确区分实测方式）

| 验收项 | 状态 | 说明 |
| --- | --- | --- |
| 打开样例书并渲染分页 | ✅ 模拟器实测 | 第一章 16 页（本轮字号/视口下），CJK/缩进/边距正常 |
| 启动稳定性（含修复的启动崩溃） | ✅ 模拟器实测 | 4 次启动全部存活；崩溃根因已定位并修复 |
| 全屏阅读界面 | ✅ 模拟器截图 | 真机交互待验 |
| 连续前后翻页不闪不跳 | ⏳ 真机待验 | 时序守卫已实现并经日志确认；拖动手感需真机 |
| 拖动预览与落页一致 | ⏳ 真机待验 | 架构不变量未变（同一份位图） |
| 目录显示并可跳转 | ⏳ 真机待验 | manifest 定位已实现；样例书可测，真实 EPUB 未验 |
| 注脚点击弹窗且不翻页 | ⏳ 真机待验 | 样例书含 2 个注脚可测；真实 EPUB 未验 |
| Files 导入 | ⏳ 真机待验 | 系统文件选择器未自动化 |
| 已下载 EPUB 打开 | ⏳ 真机待验 | 入口已接，走同一流程 |
| **真实 EPUB（你报告问题的书）** | ❌ **未验证** | 我手上没有该文件；不能以样例书代替 |

## 四、构建与交付

- 模拟器 Debug 构建：通过（iPhone 18 Pro 模拟器实测运行）。
- 未签名 IPA（真机自签后安装）：`novelia-ios-port/build/Novelia-unsigned-prototype.ipa`
  - 7,078,360 bytes · SHA-256 `b3085038b2d6e2304a719098b30a50b97e21cb787beaeeb377fb8eef36528b8e`
  - Release 配置 + `CODE_SIGNING_ALLOWED=NO`，与 CI 流程一致
- 推送：`prototype/yuedu-coretext-pager` 已推送至私密仓库 `Guanine000/novelia-ios-port`（`2827417`；本轮 `3b5358d` 提交后随即推送）。未动 `main`，未触碰其他任何仓库。
- CI：如需可在 Actions 手动 dispatch 该分支构建（上一轮 run 37757793663 为旧代码）。

## 五、遗留问题与边界

1. 真实 EPUB 全项验收未做（缺文件）——这是下一轮唯一入口任务。
2. 普通链接（书内 `<a href>`）本轮只提示不导航；外部 URL 链接同样。
3. 改字号后阅读位置按章首页首近似恢复，未做精确位置映射。
4. 容器解析仍为正则提取（原型限制见 DEPENDENCIES.md）；排版为整章一次完成，超大章节的内存/耗时未压测。
5. 仿真翻页动画按约定未开始，待翻页一致性真机验收通过后再做。

---

## 追加：第三轮修复（真机反馈后，提交 `312a58a`）

### 现象（用户真机截图）

真实 EPUB《どうせ、この夏は終わる》（spine 1/27，容器解析成功）打开即报：
"无法排版：未能完成操作。（YueduCoreText.HTMLLayoutError 错误 1。）"

### 根因

1. **错误信息不可读**：`relayout` 的 catch 直接显示 `localizedDescription`，而 `HTMLLayoutError` 未实现 `LocalizedError`，只剩枚举序号。"错误 1" 按枚举声明顺序即 `.resourceFailure(String)`（缺失图片/CSS 资源），但具体缺哪个文件被吞掉了。
2. **资源装载的三类盲区**（对照引擎源码 `HTMLResourceReferences.imageSources` 确认引擎只要求 `<img src>` 与 SVG 包裹图片、且把非空 src 一律视为待装载资源）：
   - `data:` URI 图片被我的 `isRelative` 过滤直接跳过 → 引擎查不到 → resourceFailure；
   - 包内绝对路径（`src="/OEBPS/images/x.png"`）同样被过滤；
   - 日文 EPUB 常见的百分号编码路径（HTML 里 `%E3%81%82.png`，ZIP 内是解码后的名字）查表失败。

### 修复

- 错误映射：`unsupported` 列出不支持特性清单、`resourceFailure` 点名缺失文件、`layoutFailure` 显示细节（`PrototypeReaderModel.swift` 顶层 `describeLayoutError`）。
- 资源查找：精确路径 → 百分号解码（最多两层）→ 大小写不敏感扫描全部 ZIP 条目（带缓存）；支持包内绝对路径与 `data:` base64 图片（按引擎字面 src 键入）。

### 验证状态

- 模拟器：样例书冒烟通过（进程存活、排版正常）。
- **真实 EPUB：未验证** —— 需要用新 IPA 在真机重开该书。若仍报错，新错误信息会明确写出缺失的资源文件名或不支持特性清单，截图发我即可继续定位。

### 交付物更新

- 新未签名 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,079,450 bytes · SHA-256 `64b2dff272248bed69f1505725a015cf107073f9091a960aa70bf809432f1de3`
- 提交 `312a58a` 已推送至 `Guanine000/novelia-ios-port`（未动 main）。

---

## 追加：第四轮修复（提交 `9db453a`）

### 现象（用户真机截图，新错误信息生效）

另一本真实 EPUB（spine 1/48）报："章节资源缺失：../Images/i-000a.jpg"——可读错误信息已正确点名缺失资源。

### 根因

相对资源 href（`../Images/...`、`../Styles/...`）被拼接到 **OPF 目录**上解析，而它们应相对**章节文件所在目录**解析。章节存放在 OPF 子目录（如 `OEBPS/Text/`）的书全部中招：`OEBPS/ + ../Images/x.jpg` 归一化后变成包根 `Images/x.jpg`，找不到。样例书章节与图片同目录，因此未暴露。

### 修复

- 图片 src、CSS link、@import 链全部改为相对**章节文件目录**解析（`chapterHref` 传入容器）；包内绝对路径从包根解析；percent-decode 与大小写回退保留。

### 验证状态与交付物

- 模拟器样例书冒烟通过；**真实 EPUB 待用户用新 IPA 复验**。
- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,080,010 bytes · SHA-256 `2d055290de080a147c9747b0e197a854ac19a3684efa2797f726d4e275fb11d0`

---

## 追加：第五轮修复（提交 `d423df5`）

### 用户真机反馈（书《1 / n のワタシ》，spine 1/48）

1. 报错 "本章包含当前排版引擎不支持的内容（scripted-interactive）"——路径修复已生效，卡点变为章节内嵌 `<script>`。
2. 找不到导入 EPUB 的入口。
3. 文字透明度标签（opacity/rgba）不生效。

### 处理

1. **scripted-interactive 回退**：`<script>` 块（含自闭合）在排版前剥离——脚本不产生可见正文，属回退策略而非静默丢正文；剥离数量在**目录页顶部**显示"本书包含 N 处脚本内容，已忽略"。若书中还有其他不支持特性（表格/ruby 等），错误页会继续点名。
2. **导入入口**："我的下载"右上菜单新增"从'文件'导入 EPUB…"——Files 选书 → NSFileCoordinator 复制进文库本地书库并登记（出现在下载列表）→ 直接进入原型阅读；失败弹窗提示。阅读页顶栏原有的导入按钮保留。
3. **文字透明度**：`opacity`/rgba 文字透明度在 YueduCoreText 0.8.0 支持范围之外（正文照常显示、样式不生效），属引擎已知边界，记录于此；不丢正文，后续可通过向上游提需求或宿主级 CSS 预处理解决。

### 交付物

- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,097,860 bytes · SHA-256 `65e4ed1357f8cf0314401fe61ac782d8eb7cb9cfa89bbbd70b6fb1f15f24c364`
- 模拟器冒烟通过；真实 EPUB 待用户复验（关注：打开正文 → 连续翻页 → 目录 → 注脚）。

---

## 追加：第六轮修复（提交 `7a06f77`，已用真实 EPUB 在模拟器端到端验证）

### 用户提供真实 EPUB（jp-zh.Ys.1nのワトソン，48 章，Novelia 译本）后的问题

1. 翻页无法预览、翻页卡顿；2. 目录无法跳转；3. 透明度标签未生效（已知边界）。

### 根因（真实文件解剖 + 模拟器复现）

1. **卡顿/无预览**：整章排版在主线程一次跑完。本书 48 章、每章带数百 KB 封面/插图 JPEG，跨章翻页时下一章要现排，主线程冻结数秒；拖动开始时相邻章尚未排完 → 无预览位图。
2. **目录跳转无效**：nav 的 href（`p-0001.xhtml#n0001_0001`）相对 **nav 文档目录**（`OEBPS/Text/`）解析，代码却拼到 OPF 目录 → 10 个目录项全部映射失败（日志 `mapped=0`）→ `jump` 静默返回。与第四轮 CSS/图片是同一类基准目录 bug。
3. **透明度**：`opacity`/rgba 在 YueduCoreText 0.8.0 支持范围外（本书每章 50–124 处），正文不丢、样式不生效——记录为引擎边界，暂不处理。

### 修复

- **逐页增量排版**：每排出一页立即发布（该页即可显示/预览），页间 `Task.yield()` 让路主线程，代次取消即时生效——首屏立即可用，跨章不再冻结。
- **预渲染分离**：当前页同步渲染保证首屏；相邻页只读缓存，由空闲任务预渲染（去重），拖动开始瞬间不再同步解码大 JPEG。
- **目录基准目录**：nav/NCX href 相对其文档目录解析后映射 spine——真实书日志确认 `mapped=10/10`。
- 调试通道：`-prototypeBookPath <文件>` 启动参数可直接在模拟器打开任意 EPUB（本次真实书验证即用此通道）。

### 验证状态

- 模拟器 + 真实 EPUB 实测：容器解析 48 章 ✓、封面大图渲染 ✓、逐页排版运行 ✓、目录 10/10 映射 ✓、进程稳定 ✓。
- **真机待你复验**：连续拖动翻页的手感与预览一致性、目录跳转落地、注脚弹窗。
- 透明度（opacity/rgba）仍为引擎边界，正文完整显示但样式不生效。

### 交付物

- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,102,430 bytes · SHA-256 `e56472361f2eb8c9c41810164f0eb04efafbebd0b7cf67653d8f26ea84dd5f9b`

---

## 追加：第七轮修复（提交 `ac0c856`）—— 透明度已支持

### 结论

**透明度可以显示了。** 引擎不支持 `opacity` 属性，但支持 `color: rgba(...)` 的 alpha 通道（源码 `parseColor` 确认）。本书用 `<p style="opacity:0.4">` 标记日文原文段落（每章 50–124 处），宿主现在在装载章节时把 `opacity:X` 等价改写为 `color:rgba(0,0,0,X)`（内联 style、`<style>` 块与外部 CSS 都覆盖），改写数量在目录页披露。

### 验证（真实书模拟器实测）

跳转到第一章（spine 12，26 页）：日文原文段落呈浅灰（40% alpha）、中文译文正常黑色，与书籍设计一致；进程稳定。

### 限制（记录）

- 改写按"米色底黑字"主题换算（当前原型唯一主题）；未来支持换主题/深色模式时，需把 `config.textColor` 传入换算逻辑。
- 引擎仍不支持 8 位 hex（`#RRGGBBAA`）与 `opacity` 属性本身，遇到时维持当前改写策略。

### 调试通道

- `-prototypeBookPath <文件>`：直接打开任意 EPUB；
- `-prototypeJumpSpine <n>`：打开后自动跳到指定 spine（本次目检即用）。

### 交付物

- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,107,098 bytes · SHA-256 `dd25cb6caf728a42a8ac3593ff093704857de3340b61f7d0f8ac712c1fc41df1`
- 真机验收项不变：连续翻页手感/预览一致性、目录跳转、注脚弹窗（模拟器已验证的部分见上）。

---

## 追加：第八轮修复（提交 `8479e70`）

### 用户反馈

1. 导入 EPUB 时文件选择页能打开，但 .epub 文件灰掉无法选择。
2. （看截图）阅读器仍是浮窗形式。

### 根因与修复

1. **导入不可选**：`fileImporter` 用 `UTType(filenameExtension: "epub")` 动态构造类型，未注册系统一致性声明，Files 里 .epub 被灰掉。两处导入入口（"我的下载"菜单与阅读页顶栏）都改为 `.data`（任意文件可选），合法性由容器解析校验并给出明确报错。
2. **浮窗观感**：那是我调试通道（`-openEPUBPrototype` 启动参数）用 `.sheet` 呈现导致的误导——真实路径（我的下载 → 点书）早已是全屏推入页。调试入口已改为 `fullScreenCover`，两处呈现一致（模拟器截图确认全屏、无圆角浮窗）。

### 验证状态与交付物

- 模拟器实测：全屏呈现 ✓、真实书第一章透明度（日文灰/中文黑）✓、目录 10/10 ✓、进程稳定 ✓。
- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,107,212 bytes · SHA-256 `7b5c62b6e0f5751cda8853712ecbfdb00c37185fae668c80171e5ef1b991282f`
- 已知小问题：工具栏可见时，正文首行标题会被半透明顶栏遮住一部分（覆盖式工具栏的设计取舍），后续可给正文顶部加固定内边距解决。
- 真机待复验项不变：导入选择 .epub、连续翻页手感/预览一致性、目录跳转、注脚弹窗。

---

## 追加：第九轮修复（提交 `72f5cbf`）

### 用户真机反馈

1. 点击正文内书籍自带目录页的条目，弹"原型暂不支持链接跳转（p-004.xhtml#toc-003）"而非跳转。
2. 导入文件界面仍无法选择文件（iCloud 云盘文件）。

### 根因与修复

1. **书内链接**：上一轮保守处理为"普通链接不导航"。本轮实现书内链接跳转：href 相对当前章节目录解析（复用统一基准目录逻辑）→ 映射 spine → 跳目标章首页（与目录跳转共用 `navigateToSpine`）；解析不到目标才弹提示。**限制**：同章锚点（`#fragment`）暂不精确定位，停留原页；跨章锚点落在目标章首页而非锚点处——精确锚点定位需要引擎内 source-offset 支持，记录为后续项。
2. **导入仍不可选**：SwiftUI `fileImporter` 即使放宽到 `.data`，对 iCloud 云盘未下载文件仍不可靠。两处导入入口改用 **`UIDocumentPickerViewController`**（UIKit 原生文档选择器，iCloud 按需下载可靠），安全区作用域处理不变。

### 验证状态与交付物

- 模拟器冒烟：真实书打开 ✓、目录 10/10 ✓、进程稳定 ✓。链接跳转与文件选择器为系统 UI，自动化点击不可行，**待真机复验**。
- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,110,072 bytes · SHA-256 `797734b9197ad1e9b94e47f0c06dbd63d4a14cda92567e3e3c8ab64fe4846a6a`

---

## 追加：第十轮修复（提交 `b5aa815`）

### 用户真机反馈

文档选择器能打开，但文件无法点选，右上角也没有确认/导入按钮。

### 根因与修复

1. **选择器内嵌 sheet 失效**：UIDocumentPickerViewController 包在 SwiftUI `.sheet` 里，在用户的系统版本上工具栏按钮缺失、条目不可点。改为 **`fullScreenCover` 直接全屏呈现**（"我的下载"与阅读页两处入口一致）。
2. **EPUB 类型未注册**：应用此前未声明可打开 EPUB，"打开型"文档选择器对 .epub 的启用不可靠。新增正式 `iOSApp/Info.plist`（与 GENERATE_INFOPLIST_FILE 生成键合并，已验证产物 plist 含声明）：`UTImportedTypeDeclarations`（org.idpf.epub-container，conforms public.data，扩展名 epub）+ `CFBundleDocumentTypes`。

### 验证状态与交付物

- 构建 ✓、产物 plist 已验证含 UT 声明 ✓、模拟器真实书冒烟 ✓。选择器交互需真机复验。
- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,111,204 bytes · SHA-256 `5e4ce1d7f8802ce916de9f6d9db445bef5ddd0dee9edaf4975bcd1f500e27696`

---

## 追加：第十一轮调整（提交 `eaa9a14`）

- 按用户要求："我的下载"右上角菜单**第一项改为"从'文件'导入 EPUB…"**（菜单标签也改为"导入 EPUB"），**移除测试样例书入口**（样例书生成器仅保留给调试启动参数使用）；本地书列表仍在导入项下方列出。
- 新 IPA：`build/Novelia-unsigned-prototype.ipa` · 7,109,172 bytes · SHA-256 `7259eef3283046d0a4326a428290d308a75aad708aaa458eaf43c47632240eb1`
