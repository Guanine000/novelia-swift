# Novelia iOS 優化目標

整理日期：2026-10-12　基準：公開正式版 0.11.2（構建號 46，提交 `9f687ee`）

本文件列出接手後梳理出的優化目標、現狀與建議順序。已完成或正在驗證的項目放在最前，方便對照工作區改動。

## 一、本輪已完成（工作區未提交，待真機驗收）

| 項目 | 結果 | 涉及文件 |
|---|---|---|
| 移除 Readium swift-toolkit | EPUB 導入元數據（標題、作者、簡介、封面）改由 `EPUBContainer.metadata(fileURL:coverMaxSize:)` 讀取；依賴 10 → 3；IPA 8.40 MB → 6.47 MB；合成 EPUB 與真實書籍對照與 Readium 結果一致 | `iOSApp/EPUBReader/EPUBContainer.swift`、`iOSApp/WenkuStore.swift`、`NoveliaIOS.xcodeproj/project.pbxproj`、`Package.resolved`、許可清單與檢查腳本 |
| EPUB 兩端對齊行出現大空隙、標點變半形 | 在閱讀器配置加 `config.letterSpacing = 0.001`；整本測試書大空隙行 5131 → 0 | `iOSApp/EPUBReader/EPUBReaderModel.swift` |
| 閱讀器與書庫標題不一致 | 閱讀器 `open()` 與書庫元數據共用 `mainTitle(inMetadata:)`：優先 `title-type=main` 的 `dc:title`，否則第一個；EPUB3 多標題夾具由「Subtitle Here」改為與書庫一致的「Main Title」 | `iOSApp/EPUBReader/EPUBContainer.swift` |
| 邏輯測試遷入 Swift 包測試 | 論壇 Markdown／劇透／刪除線、論壇與小說鏈接路由、版本比較與啟動更新檢查、標籤屏蔽與 WebDAV 合併、TXT 編碼與分章移入 `Sources/NoveliaIOSCore/`；`Package.swift` 新增 `NoveliaIOSCoreTests`（37 項）。因用到 UIKit，在模擬器上由 `scripts/run_package_tests.sh` 運行，而非 macOS 上的 `swift test`。6 個舊 Python 腳本已由 XCTest 取代 | `Sources/NoveliaIOSCore/`、`Tests/NoveliaIOSCoreTests/`、`Package.swift`、`scripts/` |
| 排版回歸工具化 | `NoveliaEPUB` 目標直接編譯 App 的 EPUB 容器與分頁源碼；`EPUBLayoutTests` 用合成兩端對齊 EPUB 檢查大空隙與寬度不符，並在上游修好引擎後提示移除權宜修法；`scripts/scan_epub_layout.sh` 可對任意本地 EPUB 做整書掃描 | `Tests/NoveliaEPUBTests/`、`scripts/scan_epub_layout.sh`、`EPUBPageBook.applyEngineWorkarounds` |
| 元數據對照測試 | `scripts/make_epub_fixtures.py` 生成 6 本合成 EPUB；`EPUBMetadataTests` 檢查標題、作者、簡介、封面尺寸及閱讀器標題一致 | `Tests/NoveliaEPUBTests/` |
| 命名與死代碼 | `iOSApp/EPUBPrototype/` → `iOSApp/EPUBReader/`，類型前綴 `Prototype` → `EPUB`（如 `EPUBContainer`、`EPUBReaderView`）；持久化鍵 `epubPrototype.*` 與調試啟動參數保持原名。刪除無引用的 `DemoLibrary.swift` 與 `ContinueReadingCard`；樣例書、`-openEPUBPrototype`、`-prototypeBookPath`、`-prototypeJumpSpine` 只在 Debug 構建中編譯（Release 二進制已確認不含） | `iOSApp/EPUBReader/`、`NoveliaApp.swift`、`DEPENDENCIES.md` |
| 拆分大文件 | `LibraryViews.swift`（2823 行）→ 書架、發現、作品詳情、共用組件、下載、TXT 閱讀器、設置 7 個文件；`ForumViews.swift` → 列表、帖子詳情、Markdown 渲染、編輯器 4 個文件；`NoveliaApp.swift` → 入口、標籤屏蔽、閱讀背景 3 個文件。逐行核對無增減，僅跨文件使用的類型去掉 `private` | `iOSApp/` |
| 統一設置與進度存儲 | 新增 `SettingsKey`（閱讀器、主題、WebDAV、書籤鍵）與 `ReadingProgressStore`（`progress.<id>` / `progressTime.<id>`），替換各處字面量；鍵值不變，`SettingsKeysTests` 鎖定字符串防止誤改 | `Sources/NoveliaIOSCore/SettingsKeys.swift` |
| 移除舊版逐章緩存下載兼容 | 用戶確認不存在此類下載。`DownloadedWebNovel` 去掉 `chapterDataFilename`，`fileFilename` 改為必有；刪除 `chapters(for:)`、離線章節閱讀頁、`ReaderView` 離線模式、「移至文库」的舊版錯誤提示與 WebDAV 雙文件判斷。0.11.2 寫出的下載索引仍可解碼，舊鍵在下次保存時去掉 | `WenkuStore.swift`、`DownloadsViews.swift`、`ReaderView.swift`、`WebDAVSync.swift` |

收尾待辦：

- [x] 真機驗收測試 IPA（導入、閱讀、舊書庫、開源許可頁、標點密集的對話行）。
- 模擬器 UI 回歸按用戶 2026-10-12 要求暫停；本輪只運行包邏輯／排版測試與離線回歸。
- [x] 用戶確認本輪測試版為 0.11.3（構建號 47）。
- [ ] 真機驗收第五節改動後，再按用戶指示提交與推送。

## 二、排版引擎相關（YueduCoreText）

1. **兩端對齊的根本修復**
   - 根因：引擎 `InlineLayout.justifiedLine` 只給部分字加 kern，行尾字的 kern 被移除；Core Text 遇到「部分字有 kern、部分字沒有」時，會把無 kern 的 CJK 標點擠成半形並把寬度挪到別處。上游 0.9.0 同樣存在。
   - App 端修法的殘留：全書約 2 行（含 ruby 注音的行）最後一字可能超出右邊距數 pt。
   - 已驗證的引擎修法（兩處）：`attributes(for:)` 一律設 `.kern`（含 0）；`justifiedLine` 行尾 kern 改為設 0 而非移除。整書掃描大空隙 0、寬度不符 0。
   - 待決定落地方式：在 Guanine000 下 fork 並打標籤／放入本倉庫 `Vendor/`／等上游修復。若修改引擎，需按 MPL-2.0 公開改動文件並更新許可清單與 `DEPENDENCIES.md`。
2. **已知副作用的取捨**：每字帶 kern 後，Core Text 不再自動壓縮相鄰標點、行首括號和行尾標點，標點一律全形；測試書頁數 433 → 440，617 處換行位置改變。字號、行距、段距、首行縮進、頁邊距等設置已驗證仍然有效。
3. **可選：中文排版規範模式**：引擎自帶 `cjkTypographyStyle`（簡體／繁體／日文／韓文），按 CLREQ/JLREQ 擠壓相鄰標點，配合極小字距時空隙與溢出均為 0；但會換用更寬的字體，測試書頁數 433 → 455。適合做成閱讀設置裡的選項，而不是默認值。
4. **評估升級 YueduCoreText 0.9.0**：上游 2026-10-12 發布，新增「溢出行的頁面底部對齊」，未修復上述對齊問題。升級前需重新跑許可檢查與排版回歸。

## 三、測試與質量

1. **真機驗收清單**：記憶中積壓的雙頁跨章、旋轉、長按選字、WebDAV 真實服務與跨設備合併、TXT 編碼、真實賬號接口（統一登錄、閱讀記錄上報、帖子編輯）尚未在真機完成。

## 四、結構整理

本節已全部完成。

## 五、性能與體驗

六項均已在本地實現，待本輪測試包真機驗收；實現完成不代表設備驗收完成。

| 項目 | 已實現行為 |
|---|---|
| 論壇 Markdown 解析緩存 | `ForumMarkdownCache` 緩存塊解析、劇透檢測與行內渲染；劇透正則只編譯一次。 |
| EPUB 位圖緩存上限 | 每次位置變化保留可見頁及前後各 3 頁（跨章），收到內存警告只保留可見頁，並裁剪雙頁緩存。 |
| 封面圖片緩存 | 文庫 3 處使用 `CoverImage`；480px 下採樣、48MB 內存緩存、30 天／150MB 磁盤清理及並發去重。`BookCover` 為生成圖，未改。 |
| 共享網絡層 | JSON 和 EPUB 下載共用令牌續期與 401 單次重試；GET／HEAD 對指定瞬時錯誤及 502／503／504 重試一次，超時及改寫請求不重試；統一 30／120／180 秒超時。 |
| 已棄用 API 替換 | 兩處 `NavigationLink(isActive:)` 改用 `navigationDestination(item:)`；導航目的地安裝於屏幕根部，Markdown 經環境動作觸發。 |
| EPUB 閱讀進度精度 | 新增可選 spine 章節序號與章節源文本 UTF-16 偏移，重開及重排按偏移恢復；舊進度回退全書比例，保留舊版比例字段。 |

## 日誌分享隱私（2026-10-12）

- 導出仍使用 OSLogStore，但只讀本 App 子系統並按已審查事件格式允許輸出；系統／框架日誌和未知自由文本不進入分享文件。
- 保留診斷錯誤碼、耗時、大小與數量；引擎／目錄診斷只輸出事件說明，省略詳細內容與檔案路徑。時間改為相對秒數，檔名不含時間戳或 UUID。
- 引擎完整診斷及 EPUB 導航檔案路徑的 OSLog 動態值改為 private，保護後續記錄；導出允許清單也覆蓋舊日誌。
- 新增 ShareableLogPolicyTests：UUID、路徑、URL／令牌、郵箱、書名正文、系統日誌、偽造字段與換行後綴不能出現在導出內容中。Core 共 41 項全過，EPUB 7 過／1 按設計跳過；未运行模擬器 UI 測試。
- 版本維持 0.11.3，新內容測試包使用構建 48，保留已交付的構建 47。真機仍需驗收「我的 → 導出應用日誌」與分享文件內容。

## 六、共用設定與本機發布（2026-10-12）

1. **ReaderSettings 已實現，待真機驗收**：三套閱讀器與全局設置頁共用字號（12–36）及 light／dark／system 外觀；背景共用既有 ReaderBackgroundStore。EPUB 特有版面選項保留；動畫／排版中推遲套用共同變化。舊 readerFontSize 優先，缺失時讀舊 EPUB 字號；僅讀取不寫入遷移，調整字號後同步原全局鍵與 EPUB 樣式字號，不改其他鍵名。進度共用存取入口，保留章索引／spine偏移與 WebDAV 格式；TXT 仍僅有會話內章節位置。
2. **在線與 TXT 分頁評估已完成**：建議先抽出章節內容來源接口、再做 TXT 分頁、最後在線原文／譯文／雙語適配；保留段落與源文本偏移、取消／預取、書籤與章節上報。未切換閱讀引擎；實施與驗收清單見 READER_PAGINATION.md。
3. **本機發布腳本已實現**：scripts/build_local_release.py 串接包測試、離線回歸、Release構建、原始依賴與包內許可核對、IPA隱私檢查、精確依賴源碼、完整工作區源碼與 SHA256SUMS。拒絕覆蓋已有產物；未提交源碼須明確 --allow-dirty，構建中源碼變化則拒絕交付。不依賴 Actions，不處理賬單，不提交／推送／發布。使用方法見 README。

## 建議順序

1. 收尾本輪改動：交付 0.11.3(47) 本地測試包 → 用戶真機驗收 → 按用戶指示提交與推送。
2. 決定引擎修復的落地方式（第二節第 1 項）。
3. 第六節設定與本機腳本已實現；在線／TXT 分頁依評估逐步遷移，待後續指示。
