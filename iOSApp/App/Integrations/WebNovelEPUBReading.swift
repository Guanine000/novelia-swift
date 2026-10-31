// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Combine
import SwiftSoup

/// 网络小说阅读的集成入口。目录服务、实际下载Store和共用阅读状态在此连接，文库不使用此入口。
struct WebNovelEPUBReader: View {
    let book: DownloadedWebNovel
    var managementOnly = false
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var downloads: WebNovelDownloadStore
    var body: some View {
        WebNovelEPUBReaderContent(book: book, catalog: services.api.catalog, content: services.api.content,
                                  settings: services.local.readerSettings, downloads: downloads, managementOnly: managementOnly)
    }
}

@MainActor
private final class WebNovelEPUBReadingModel: ObservableObject {
    @Published var book: DownloadedWebNovel
    @Published var url: URL
    @Published var context: WebNovelEPUBContext? {
        didSet { revision = hash + (context?.chapterIDs.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "|") ?? "") }
    }
    @Published private(set) var revision = ""
    @Published var paths: [String] = []
    @Published var titles: [String] = []
    @Published var latest: Novel?
    @Published var error: String?
    @Published var message: String?
    @Published var checkedAt: Date?
    struct Preview { let local: String; let remote: String }
    @Published var preview: Preview?
    @Published var suggestedIDs: [String] = []
    @Published var filteringCandidates = false
    @Published var fullDirectory = false
    @Published var correctingBindings = false
    @Published var checking = false
    @Published var updating = false
    @Published var verificationProgress: String?
    @Published var selectedLocal = 0
    @Published var selectedRemote = ""
    @Published var nextChapter: String?
    let catalog: any NovelCatalogService
    let content: any NovelContentService
    let settings: ReaderSettings
    let downloads: WebNovelDownloadStore
    private var container: EPUBContainer?
    private var storyPaths: [String] = []
    private var storyPathSet: Set<String> = []
    private var directoryByPath: [String: WebNovelEPUBTOCMatcher.Entry] = [:]
    private var remoteOrder: [String: Int] = [:]
    private var directoryEntries: [WebNovelEPUBTOCMatcher.Entry] = []
    private var readable: Set<String> = []
    private var hash = ""
    private var lastChapterID: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var candidateTask: Task<Void, Never>?
    private var candidateVersion = UUID()
    var key: String { WebNovelEPUBContext.key(provider: book.novel.providerId ?? "", novel: book.novel.novelId ?? "") }
    var missing: Bool { settings.missingWebEPUBChapter(context: context, paths: paths) }
    var missingCount: Int? {
        guard let latest, let context, !storyPaths.isEmpty,
              storyPaths.allSatisfy({ context.chapterIDs[$0] != nil && readable.contains($0) }) else { return nil }
        return Set(latest.chapters.map(\.id)).subtracting(Set(context.chapterIDs.values)).count
    }


    init(book: DownloadedWebNovel, catalog: any NovelCatalogService, content: any NovelContentService,
         settings: ReaderSettings, downloads: WebNovelDownloadStore) {
        self.book = book; self.catalog = catalog; self.content = content; self.settings = settings; self.downloads = downloads
        url = downloads.fileURL(for: book)
        settings.positions.changes.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        settings.webEPUBMaps.$maps.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMap() }
        }.store(in: &subscriptions)
    }
    private func refreshMap() {
        guard context != nil, !hash.isEmpty, !paths.isEmpty else { return }
        let updated = settings.webEPUBMaps.context(bookKey: key, hash: hash)
        guard updated != context else { return }
        do {
            try WebNovelEPUBMigration.migrate(context: updated, paths: paths, settings: settings)
            readable = Set(updated.chapterIDs.keys).intersection(storyPathSet)
            context = updated
            refreshSelection()
        } catch { self.error = "阅读状态迁移未保存：\(error.localizedDescription)" }
    }
    func load() async {
        do {
            let file = url
            let current = try await Task.detached(priority: .utility) { try await EPUBContainer.open(fileURL: file) }.value
            let digest = try await Task.detached(priority: .utility) { try FileContentHash.sha256(file) }.value
            try Task.checkCancellation()
            container = current; hash = digest; paths = current.spine.map(\.href)
            readable.removeAll()
            var tocTitles: [Int: String] = [:]
            for entry in current.toc { if let index = entry.spineIndex { tocTitles[index] = entry.title } }
            titles = paths.indices.map { tocTitles[$0] ?? "第 \($0 + 1) 个章节资源" }
            storyPaths = paths.filter { $0.range(of: #"(?:^|/)episode[0-9]+\.xhtml$"#, options: .regularExpression) != nil }
            if storyPaths.isEmpty { storyPaths = paths }
            storyPathSet = Set(storyPaths)
            let parents = TOCOutline.parents(levels: current.toc.map(\.level))
            let groups = TOCOutline.hasChildren(levels: current.toc.map(\.level))
            var flatVolume: String?
            directoryEntries = current.toc.indices.compactMap { i in
                let entry = current.toc[i]
                if groups[i] || entry.spineIndex == nil { flatVolume = entry.title; return nil }
                guard let index = entry.spineIndex, paths.indices.contains(index), storyPathSet.contains(paths[index]) else { return nil }
                let volume = parents[i].map { current.toc[$0].title } ?? (entry.level == 0 ? flatVolume : nil)
                return WebNovelEPUBTOCMatcher.Entry(path: paths[index], title: entry.title, volume: volume)
            }
            directoryByPath = Dictionary(directoryEntries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let map = settings.webEPUBMaps.context(bookKey: key, hash: hash)
            // 旧记录仅在已确认的章节迁移。完全未映射的旧书仍可按哈希离线阅读。
            try WebNovelEPUBMigration.migrate(context: map, paths: paths, settings: settings)
            readable = Set(map.chapterIDs.keys).intersection(storyPathSet)
            context = map
            selectedLocal = min(max(0, settings.epubPosition(hash: hash, context: context, paths: paths)?.chapterIndex ?? 0), max(0, paths.count - 1))
            lastChapterID = storyPaths.last.flatMap { map.chapterIDs[$0] }
            refreshSelection()
        } catch is CancellationError { self.error = "准备已取消，可重试打开。" } catch { self.error = error.localizedDescription }
    }
    func preparePanel() {
        let position = settings.epubPosition(hash: hash, context: context, paths: paths)?.chapterIndex ?? selectedLocal
        selectLocal(pendingIndices.contains(position) ? position : pendingIndices.first ?? position)
    }
    var storyIndices: [Int] { paths.indices.filter { storyPathSet.contains(paths[$0]) } }
    var pendingIndices: [Int] { storyIndices.filter { context?.chapterIDs[paths[$0]] == nil } }
    var remoteOptions: [NovelChapter] {
        let ids = Set(suggestedIDs)
        var seen: Set<String> = []
        return (latest?.chapters ?? []).filter { (fullDirectory || ids.contains($0.id)) && seen.insert($0.id).inserted }
    }
    func localLabel(_ index: Int) -> String {
        let volume = paths.indices.contains(index) ? directoryByPath[paths[index]]?.volume : nil
        return "第 \(index + 1) 项 · " + [volume, titles.indices.contains(index) ? titles[index] : nil].compactMap { $0 }.joined(separator: " · ")
    }
    func remoteLabel(_ chapter: NovelChapter) -> String {
        let index = remoteOrder[chapter.id] ?? 0
        return "第 \(index + 1) 章 · " + [chapter.volumeTitle, chapter.title].compactMap { $0 }.joined(separator: " · ")
    }
    var localNeighbors: String {
        let indices = storyIndices
        guard let i = indices.firstIndex(of: selectedLocal) else { return "" }
        return "前章：" + (i > 0 ? titles[indices[i - 1]] : "无") + "\n后章：" + (i + 1 < indices.count ? titles[indices[i + 1]] : "无")
    }
    var remoteNeighbors: String {
        guard let chapters = latest?.chapters, let i = remoteOrder[selectedRemote] else { return "请选择网站章节" }
        return "前章：" + (i > 0 ? chapters[i - 1].title : "无") + "\n后章：" + (i + 1 < chapters.count ? chapters[i + 1].title : "无")
    }
    var replacesBinding: Bool {
        guard paths.indices.contains(selectedLocal), let context else { return false }
        return context.chapterIDs.contains { ($0.key == paths[selectedLocal] && $0.value != selectedRemote) || ($0.key != paths[selectedLocal] && $0.value == selectedRemote) }
    }
    func selectLocal(_ index: Int) {
        selectedLocal = index; fullDirectory = false; preview = nil
        refreshSelection()
    }
    func refreshSelection() {
        candidateTask?.cancel(); candidateVersion = UUID(); filteringCandidates = false
        if !correctingBindings, !pendingIndices.contains(selectedLocal), let first = pendingIndices.first { selectedLocal = first }
        guard paths.indices.contains(selectedLocal), let latest else { selectedRemote = ""; suggestedIDs = []; return }
        let version = candidateVersion
        filteringCandidates = true
        suggestedIDs = []; selectedRemote = ""; preview = nil
        let path = paths[selectedLocal], entries = directoryEntries, remote = latest.chapters
        let saved = book.novel.chapters, existing = context?.chapterIDs ?? [:], fileHash = hash, index = selectedLocal
        candidateTask = Task {
            defer { if candidateVersion == version { filteringCandidates = false } }
            let ids = await Task.detached(priority: .utility) {
                WebNovelEPUBTOCMatcher.candidates(path: path, local: entries, remote: remote, saved: saved, existing: existing)
            }.value
            guard !Task.isCancelled, hash == fileHash, selectedLocal == index else { return }
            suggestedIDs = ids
            selectedRemote = ids.count == 1 ? ids[0] : ""
        }
    }
    func chooseRemote(_ value: String) {
        candidateTask?.cancel(); candidateVersion = UUID(); filteringCandidates = false
        selectedRemote = value; preview = nil
    }
    func chooseFullDirectory(_ enabled: Bool) {
        candidateTask?.cancel(); candidateVersion = UUID(); filteringCandidates = false
        fullDirectory = enabled; selectedRemote = ""; preview = nil
    }
    func check() async {
        guard !checking, let provider = book.novel.providerId, let novel = book.novel.novelId else { return }
        checking = true; defer { checking = false }; error = nil
        do {
            let value = try await catalog.novel(providerId: provider, novelId: novel)
            try Task.checkCancellation()
            guard value.providerId == provider, value.novelId == novel else { throw WebDAVSyncError.invalidAsset }
            latest = value
            remoteOrder = Dictionary(value.chapters.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            checkedAt = Date()
            // 同一hash的确认记录已经排除了缺章/缺译，打开面板无需再次扫描正文。
            refreshSelection()
        } catch is CancellationError {} catch { self.error = "暂时无法检查更新：\(error.localizedDescription)" }
    }
    private func document(_ index: Int) async throws -> (heading: String, original: String, translated: String) {
#if DEBUG
        ArchitectureNetworkTrap.serviceCalled("localEPUBDocument")
#endif
        guard let container else { throw WebDAVSyncError.invalidAsset }
        return try await Task.detached(priority: .utility) {
            let html = try await container.chapterHTML(at: index)
            let doc = try SwiftSoup.parse(html)
            let heading = try doc.select("h1,h2").array().map { try $0.text() }.joined(separator: "\u{1f}")
            let paragraphs = try doc.select("p").array()
            let all = try paragraphs.map { try $0.text() }.joined(separator: "\n")
            let jp = try doc.select("p[lang=ja]").array().map { try $0.text() }.joined(separator: "\n")
            return (heading, jp.isEmpty ? all : jp, all)
        }.value
    }
    private static func normalize(_ text: String) -> String { text.filter { !$0.isWhitespace && !$0.isNewline } }
    func confirm() async {
        guard paths.indices.contains(selectedLocal), !selectedRemote.isEmpty else { return }
        let localIndex = selectedLocal, remoteID = selectedRemote, fileHash = hash
        error = nil
        do {
            guard latest?.chapters.contains(where: { $0.id == remoteID }) == true else { throw WebDAVSyncError.invalidAsset }
            let doc = try await document(localIndex)
            guard localIndex == selectedLocal, remoteID == selectedRemote, fileHash == hash else { return }
            guard !Self.normalize(doc.translated).isEmpty, !doc.translated.contains("该章节缺失。"), !doc.translated.contains("翻译缺失。") else { throw WebDAVSyncError.invalidAsset }
            try bind(index: localIndex, id: remoteID)
            readable.insert(paths[localIndex])
            message = "已保存该章节对应，原进度和书签已尝试迁移。"
            let pending = pendingIndices
            if let next = pending.first(where: { $0 > selectedLocal }) ?? pending.first { selectLocal(next) }
            else { preview = nil }
        } catch { self.error = "章节对应未保存：\(error.localizedDescription)" }
    }
    func showPreview() async {
        guard paths.indices.contains(selectedLocal), let provider = book.novel.providerId, let novel = book.novel.novelId,
              !selectedRemote.isEmpty else { return }
        let localIndex = selectedLocal, remoteID = selectedRemote, fileHash = hash
        do {
            let local = try await document(localIndex)
            let remote = try await content.chapter(providerId: provider, novelId: novel, chapterId: remoteID)
            try Task.checkCancellation()
            guard localIndex == selectedLocal, remoteID == selectedRemote, fileHash == hash else { return }
            preview = Preview(local: String(local.translated.prefix(500)), remote: String((book.resolvedDownloadMode == .original ? remote.originalText : remote.translatedText).prefix(500)))
        } catch { self.error = "未能读取章节预览：\(error.localizedDescription)" }
    }
    private func bind(index: Int, id: String) throws {
        try Task.checkCancellation()
        var map = settings.webEPUBMaps.maps[key + ":" + hash] ?? WebNovelEPUBMap(bookKey: key, fileHash: hash, bindings: [:])
        // 人工更正时清除同文件里相同ID的旧对应，避免一章对应多个资源。
        for (path, binding) in map.bindings where binding.chapterID == id && path != paths[index] {
            map.bindings[path] = WebNovelEPUBBinding(chapterID: id, updatedAt: Date(), deleted: true)
        }
        map.bindings[paths[index]] = WebNovelEPUBBinding(chapterID: id, updatedAt: Date())
        guard map.isValid else { throw WebDAVSyncError.invalidAsset }
        try settings.webEPUBMaps.merge([map.key: map])
        let updated = settings.webEPUBMaps.context(bookKey: key, hash: hash)
        try WebNovelEPUBMigration.migrate(context: updated, paths: paths, settings: settings)
        context = updated
        lastChapterID = storyPaths.last.flatMap { updated.chapterIDs[$0] }
    }
    /// 只请求/复用网站目录，正文检查仅在本地文件完成；歧义留给手动确认，不按序号猜测。
    func verifyAll() async {
        guard verificationProgress == nil else { return }
        if latest == nil { await check() }
        guard let latest else { return }
        error = nil
        verificationProgress = "正在比较目录…"
        defer { verificationProgress = nil }
        let localEntries = directoryEntries, remote = latest.chapters, saved = book.novel.chapters
        let existing = context?.chapterIDs ?? [:]
        do {
            let proposals = await Task.detached(priority: .utility) {
                WebNovelEPUBTOCMatcher.match(local: localEntries, remote: remote, saved: saved, existing: existing)
            }.value
            let indices = Dictionary(paths.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            var batch: [String: String] = [:]
            for (number, path) in storyPaths.enumerated() {
                try Task.checkCancellation()
                guard context?.chapterIDs[path] == nil, let id = proposals[path], let index = indices[path] else { continue }
                if batch.isEmpty { verificationProgress = "正在核对本机章节 \(number + 1)/\(storyPaths.count)" }
                let doc = try await document(index)
                let body = Self.normalize(doc.translated)
                guard !body.isEmpty, !body.contains("该章节缺失。"), !body.contains("翻译缺失。") else { continue }
                batch[path] = id
                if batch.count >= 64 { try applyVerified(batch); batch.removeAll(); await Task.yield() }
            }
            try Task.checkCancellation()
            if !batch.isEmpty { try applyVerified(batch) }
            if let first = pendingIndices.first { selectLocal(first) }
            message = missingCount == nil ? "仍有章节目录无法唯一对应，请在下方逐章确认。原书和旧状态保留。" : "章节核对完成。"
        } catch is CancellationError { message = "已停止核对，已完成批次的对应已保存。" }
        catch { self.error = "核对未完成：\(error.localizedDescription)" }
    }
    /// 每批只写入和迁移一次；提交时复读，保护同步期间已有的确认和墓碑。
    private func applyVerified(_ bindings: [String: String]) throws {
#if DEBUG
        ArchitectureNetworkTrap.serviceCalled("localEPUBBatch")
#endif
        var map = settings.webEPUBMaps.maps[key + ":" + hash] ?? WebNovelEPUBMap(bookKey: key, fileHash: hash, bindings: [:])
        var used = Set(map.bindings.values.map(\.chapterID))
        let time = Date()
        for (path, id) in bindings where map.bindings[path] == nil && !used.contains(id) {
            map.bindings[path] = .init(chapterID: id, updatedAt: time); used.insert(id)
        }
        try settings.webEPUBMaps.merge([map.key: map])
        let updated = settings.webEPUBMaps.context(bookKey: key, hash: hash)
        try WebNovelEPUBMigration.migrate(context: updated, paths: paths, settings: settings)
        readable = Set(updated.chapterIDs.keys).intersection(storyPathSet)
        context = updated
        lastChapterID = storyPaths.last.flatMap { updated.chapterIDs[$0] }
    }
    func update(configuration: WebNovelEPUBUpdateConfiguration? = nil) async {
        guard !updating else { return }
        updating = true; defer { updating = false }; error = nil
        var fileCommitted = false
        do {
            let oldLast = lastChapterID
            let changed = try await downloads.updateEPUB(book, configuration: configuration)
            if changed, let current = downloads.books.first(where: { $0.id == book.id }) {
                fileCommitted = true
                book = current; url = downloads.fileURL(for: current); readable = []; nextChapter = nil
                context = nil; container = nil; paths = []; titles = []
                await load()
                guard context != nil else { message = "文件已更新，请返回后重试打开；后续章节核对尚未完成。"; return }
                await check()
                if let oldLast, let chapters = latest?.chapters, let index = chapters.firstIndex(where: { $0.id == oldLast }), chapters.indices.contains(index + 1) {
                    nextChapter = chapters[index + 1].id
                }
                message = "EPUB 已更新，阅读位置按已确认章节恢复。可核对新版章节后继续阅读。"
            } else {
                if let current = downloads.books.first(where: { $0.id == book.id }) { book = current }
                message = "文件内容没有变化，原阅读位置保留。"
            }
        } catch {
            self.error = fileCommitted ? "文件已更新，后续章节核对尚未完成：\(error.localizedDescription)" : (Task.isCancelled ? "已取消更新，未提交的文件已清理。" : "更新失败：\(error.localizedDescription)")
        }
    }
    func continueReading() {
        error = nil
        guard let id = nextChapter, context?.chapterIDs.values.contains(id) == true else {
            error = "请先核对新版章节对应，再继续阅读新章节。"; return
        }
        settings.positions.mergePosition(key: key, position: SyncedReadingPosition(chapterIndex: nil, fraction: nil,
            updatedAt: Date(), chapterProgression: 0, chapterID: id))
        nextChapter = nil
        // 重建阅读器时通过稳定ID定位，保存动作仅由此显式操作触发。
        context = context.map { WebNovelEPUBContext(bookKey: $0.bookKey, fileHash: $0.fileHash, chapterIDs: $0.chapterIDs, legacyHashes: $0.legacyHashes) }
    }
}

private struct WebNovelEPUBReaderContent: View {
    @Environment(\.dismiss) private var dismiss
    let managementOnly: Bool
    @StateObject private var model: WebNovelEPUBReadingModel
    @State private var showingPanel = false
    @State private var choosingUpdateConfiguration = false
    @State private var readerIdentity = ""
    @State private var confirmingCorrection = false
    @State private var atEnd = false
    @State private var operation: Task<Void, Never>?
    @State private var readerRevision = UUID()
    init(book: DownloadedWebNovel, catalog: any NovelCatalogService, content: any NovelContentService,
         settings: ReaderSettings, downloads: WebNovelDownloadStore, managementOnly: Bool) {
        self.managementOnly = managementOnly
        _model = StateObject(wrappedValue: WebNovelEPUBReadingModel(book: book, catalog: catalog, content: content, settings: settings, downloads: downloads))
    }
    var body: some View {
        Group {
            if managementOnly { panel }
            else { reader }
        }
    }
    private var reader: some View {
        ZStack {
            if model.context != nil {
                EPUBReaderHost(initialURL: model.url, statisticsID: "web:" + model.book.id, statisticsTitle: model.book.novel.title,
                    webContext: model.context, onReachedEnd: { atEnd = true; showingPanel = true })
                    .id(readerIdentity + readerRevision.uuidString)
            } else {
                ProgressView("正在准备阅读…")
                if let error = model.error { Text(error); Button("重试") { Task { await model.load() } } }
            }
        }
        .task { await model.load(); readerIdentity = model.revision; if model.missing { showingPanel = true } }
        .onChange(of: model.revision) { _, value in if !showingPanel { readerIdentity = value } }
        // 操作面板打开期间不重建背后的阅读器；返回时再应用新文件/映射，避免隐藏导航栏抢占面板。
        .sheet(isPresented: $showingPanel, onDismiss: { readerIdentity = model.revision }) { panel }
    }
    private var panel: some View {
        NavigationStack {
            Form {
                if model.context == nil {
                    ProgressView("正在准备本机目录…")
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                } else {
                if atEnd { Section { Text("已读完本机已下载章节").font(.title3.bold()); Text(model.book.novel.title) } }
                if model.missing { Section { Text("本机版本未包含同步位置的章节，或该章节尚未核对。请核对章节对应或更新 EPUB。") } }
                Section("章节更新") {
                    if model.checking { ProgressView("正在检查最新目录…") }
                    else if let count = model.missingCount {
                        Text(count == 0 ? "本机已包含网站当前全部章节" : "还有 \(count) 章未下载")
                    } else { Text("暂无法确认未下载数量，请核对本机章节。") }
                    if let date = model.checkedAt { Text("上次检查：" + date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text("按网站目录计算；译文是否可用取决于网站。").font(.caption).foregroundStyle(.secondary)
                    Button("重新检查更新") { start { await model.check() } }.disabled(model.checking || model.updating)
                    Button("更新至最新章节") {
                        if model.book.epubUpdateConfiguration == nil { choosingUpdateConfiguration = true }
                        else { start { await model.update() } }
                    }.disabled(model.updating || model.verificationProgress != nil)
                    if model.updating { ProgressView("正在更新 EPUB…") }
                    if model.nextChapter != nil && !managementOnly { Button("继续阅读新章节") { model.continueReading(); readerRevision = UUID(); if model.error == nil { if managementOnly { dismiss() } else { showingPanel = false } } } }
                }
                Section("已下载书籍的章节核对") {
                    Text("旧书无需重新下载。按目录核对不会读取网站正文；同名或无法匹配的章节，可预览后手动确认。")
                    if let progress = model.verificationProgress { ProgressView(progress) }
                    Button("按目录核对章节") { start { await model.verifyAll() } }.disabled(model.verificationProgress != nil || model.updating)
                    Text("待确认 \(model.pendingIndices.count) 章").accessibilityIdentifier("web-epub-pending-count")
                    Toggle("更正已确认章节", isOn: $model.correctingBindings)
                        .onChange(of: model.correctingBindings) { _, enabled in
                            if !enabled, let first = model.pendingIndices.first { model.selectLocal(first) }
                        }
                    if model.correctingBindings || !model.pendingIndices.isEmpty {
                        NavigationLink {
                            WebEPUBChapterChoices(title: "本机待确认章节", choices: (model.correctingBindings ? model.storyIndices : model.pendingIndices).map {
                                .init(id: String($0), label: model.localLabel($0))
                            }, selected: String(model.selectedLocal)) { value in
                                if let index = Int(value) { model.selectLocal(index) }
                            }
                        } label: {
                            LabeledContent("待确认章节", value: model.localLabel(model.selectedLocal))
                        }.accessibilityIdentifier("web-epub-local-selection")
                        Text(model.localNeighbors).font(.caption).foregroundStyle(.secondary)
                        if model.filteringCandidates { ProgressView("正在筛选候选…") }
                        else { Text("网站候选 \(model.suggestedIDs.count) 项").font(.caption) }
                        Toggle("从完整网站目录选择", isOn: Binding(get: { model.fullDirectory }, set: { model.chooseFullDirectory($0) }))
                        NavigationLink {
                            WebEPUBChapterChoices(title: "网站章节候选", choices: model.remoteOptions.map {
                                .init(id: $0.id, label: model.remoteLabel($0))
                            }, selected: model.selectedRemote) { value in
                                model.chooseRemote(value)
                            }
                        } label: {
                            LabeledContent("网站章节", value: model.remoteOptions.first(where: { $0.id == model.selectedRemote }).map { model.remoteLabel($0) } ?? "请选择")
                        }.accessibilityIdentifier("web-epub-remote-selection")
                        .disabled(model.filteringCandidates && !model.fullDirectory)
                        Text(model.remoteNeighbors).font(.caption).foregroundStyle(.secondary)
                        if model.suggestedIDs.isEmpty && !model.filteringCandidates { Text("没有可唯一筛选的同名候选，可从完整网站目录选择。已确认的对应不会自动覆盖。").font(.caption) }
                        Button("查看所选章节正文") { start { await model.showPreview() } }.disabled(model.selectedRemote.isEmpty || model.updating)
                        if let preview = model.preview {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading) { Text("本机正文").bold(); Text(preview.local) }.frame(maxWidth: .infinity, alignment: .topLeading)
                                VStack(alignment: .leading) { Text("网站正文").bold(); Text(preview.remote) }.frame(maxWidth: .infinity, alignment: .topLeading)
                            }.font(.footnote).textSelection(.enabled)
                        }
                        Text("确认后保存对应，并自动进入下一条待确认章节。").font(.caption)
                        Button("确认这两个章节对应") {
                            if model.replacesBinding { confirmingCorrection = true }
                            else { start { await model.confirm() } }
                        }.disabled(model.selectedRemote.isEmpty || model.updating || model.verificationProgress != nil)
                        .confirmationDialog("更正已有章节对应？", isPresented: $confirmingCorrection, titleVisibility: .visible) {
                            Button("更正并继续") { start { await model.confirm() } }
                        } message: { Text("这会替换已有对应，同一网站章节只保留一个本机对应。") }
                    } else { Text("本机章节已全部确认。需要修改时可开启更正。") }
                }
                if let message = model.message { Section { Text(message) } }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                if operation != nil { Button("取消当前操作", role: .cancel) { operation?.cancel() } }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text(atEnd ? "章节已读完" : "章节同步与更新").font(.headline)
                Spacer()
                Button(managementOnly ? "关闭" : "返回阅读") {
                    if managementOnly { dismiss() } else { showingPanel = false }
                }
            }.padding(.horizontal).padding(.vertical, 10).background(.bar)
        }
        .sheet(isPresented: $choosingUpdateConfiguration) {
            WebNovelEPUBUpdateOptionsSheet(book: model.book) { configuration in
                choosingUpdateConfiguration = false
                start { await model.update(configuration: configuration) }
            }
        }
        .task {
            if managementOnly { await model.load() }
            model.preparePanel(); await model.check()
        }
        .onDisappear { operation?.cancel() }
    }
    private func start(_ work: @escaping @MainActor () async -> Void) {
        guard operation == nil else { return }
        operation = Task { await work(); operation = nil }
    }
}

/// 显式管理候选页的返回，避免系统Picker继承阅读器隐藏导航栏后无法退出。
private struct WebEPUBChapterChoices: View {
    struct Choice: Identifiable { let id: String; let label: String }
    let title: String
    let choices: [Choice]
    let selected: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        List {
            ForEach(choices.filter { search.isEmpty || $0.label.localizedStandardContains(search) }) { choice in
                Button {
                    onSelect(choice.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(choice.label).foregroundStyle(.primary)
                        Spacer()
                        if choice.id == selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }.accessibilityLabel(choice.label)
            }
        }
        .searchable(text: $search, prompt: "搜索章节标题或序号")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
