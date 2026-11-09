// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 系列是用户明确选择的作品容器；展示排序不当作阅读卷序，必须确认后才能生成或查看。
@MainActor
struct CharacterSeriesView: View {
    let workID: String
    let books: [LibraryBook]
    @ObservedObject var store: CharacterLexiconStore
    @ObservedObject var ai: ReadingAIStore
    var initialBook: String? = nil
    var readingBoundary: Int? = nil
    var readingIdentity: String? = nil
    var initialQuery = ""
    @EnvironmentObject private var settings: ReaderSettings
    @State private var order = [String]()
    @State private var currentBook = ""
    @State private var targetBook = ""
    @State private var start = 0
    @State private var query = ""
    @State private var scopeReady = false
    @State private var identities: [String: String] = [:]
    @State private var current: CharacterVolumeLoader.Volume?
    @State private var target: CharacterVolumeLoader.Volume?
    @State private var chapters = [RecapChapter]()
    @State private var plan: CharacterExtractionPlan?
    @State private var candidates = [CharacterCandidate]()
    @State private var message: String?
    @State private var progress: String?
    @State private var generation: Task<Void, Never>?
    @State private var token = UUID()
    @State private var manualName = ""
    @State private var manualText = ""
    @State private var manualQuote = ""
    @State private var manualChapter = 0
    private var confirmed: Bool { !order.isEmpty && store.order(work: workID) == order }
    private var scope: CharacterScope? {
        guard confirmed, scopeReady, let current else { return nil }
        let boundary = currentBook == initialBook ? readingBoundary ?? current.boundary : current.boundary
        return .init(work: workID, volumes: order, currentBook: currentBook, currentChapter: boundary, identities: identities)
    }
    private var visible: [VisibleCharacter] { scope.map { $0.visible(store.entities, query: query) } ?? [] }
    private var eligibleBooks: [String] {
        guard let i = order.firstIndex(of: currentBook) else { return [] }
        return Array(order.prefix(i + 1))
    }
    private var upper: Int {
        guard let scope, let target else { return 0 }
        return targetBook == currentBook ? min(scope.currentChapter, target.source.currentChapter) : target.source.currentChapter
    }
    private var loadID: String { currentBook + "|" + order.joined(separator: ",") + "|\(settings.projectionRevision)|\(confirmed)" }
    private var targetID: String { targetBook + "|" + loadID + "|\(scopeReady)|" + (current?.source.identity ?? "") }
    private var rangeID: String { targetBook + "|\(start)|\(upper)|" + (target?.source.identity ?? "") }
    private func title(_ key: String) -> String { books.first { $0.key == key }?.title ?? "缺失的卷" }

    var body: some View {
        List {
            orderSection
            if confirmed {
                scopeSection
                if let scope {
                    Section {
                        TextField("按当前可见人名／别名查找", text: $query)
                        ForEach(visible) { person in
                            NavigationLink {
                                CharacterCardView(id: person.id, scope: scope, books: books, store: store)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(person.name)
                                    if !person.aliases.isEmpty { Text(person.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if visible.isEmpty { Text("此范围暂无已收录人物，可生成候选或手工添加。").foregroundStyle(.secondary) }
                    } header: { Text("人物表") }
                    extractionSection(scope)
                    candidatesSection(scope)
                    manualSection(scope)
                }
            }
            if let progress {
                Section { HStack { ProgressView(); Text(progress) }; Button("取消") { cancel() } }
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("跨卷人物词条")
        .toolbar { ToolbarItem(placement: .compatTopBarTrailing) { EditButton().disabled(progress != nil) } }
        .onAppear {
            guard order.isEmpty else { return }
            let saved = store.order(work: workID).filter { key in books.contains { $0.key == key } }
            let remaining = books.filter { !saved.contains($0.key) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.key)
            query = initialQuery
            order = saved + remaining
            currentBook = order.contains(initialBook ?? "") ? initialBook! : order.first ?? ""
            targetBook = currentBook
        }
        .task(id: loadID) { await loadScope() }
        .task(id: targetID) { await loadTarget() }
        .task(id: rangeID) { await prepare() }
        .onDisappear { cancel() }
    }
    private var orderSection: some View {
        Section {
            ForEach(order, id: \.self) { key in Text(title(key)) }
                .onMove { offsets, destination in cancel(); order.move(fromOffsets: offsets, toOffset: destination) }
            Button(confirmed ? "卷序已确认" : "确认以上卷序") {
                do { try store.confirmOrder(work: workID, volumes: order) }
                catch { message = error.localizedDescription }
            }.disabled(confirmed || progress != nil)
        } header: { Text("先确认卷序（编辑可拖动）") } footer: {
            Text("前卷按已读处理，不逐卷追踪是否读过。作品由系列 ID 标识，重命名不合并人物；新增卷后需重新确认顺序。")
        }
    }
    private var scopeSection: some View {
        Section {
            Picker("当前阅读卷", selection: $currentBook) {
                ForEach(order, id: \.self) { Text(title($0)).tag($0) }
            }.disabled(progress != nil)
            if let scope {
                Text("当前第 \(scope.currentChapter + 1) 章之前可见；当前章和后续章隐藏。")
                let missing = eligibleBooks.filter { identities[$0] == nil }
                if !missing.isEmpty { Text("未载入／缺失：" + missing.map(title).joined(separator: "、")).font(.footnote) }
            }
        }
    }
    private func extractionSection(_ scope: CharacterScope) -> some View {
        Section {
            Picker("提取所在卷", selection: $targetBook) {
                ForEach(eligibleBooks, id: \.self) { Text(title($0)).tag($0) }
            }.disabled(progress != nil)
            if upper > 0 {
                Stepper("从第 \(start + 1) 章起，最多 3 章", value: $start, in: 0...max(0, upper - 1)).disabled(progress != nil)
            }
            if let plan {
                Text("发送《\(title(targetBook))》第 \(start + 1)–\(min(start + 3, upper)) 章，共 \(plan.chunks.count) 个分块至所配置 AI 接口；可能产生费用。")
                    .font(.footnote)
                Button("发送并生成人物候选") { generate(plan) }.disabled(progress != nil || !ai.configuration.isEnabled)
            }
            if !ai.configuration.isEnabled { Text("请先在 AI 阅读辅助设置中启用服务。").font(.footnote) }
        } header: { Text("按范围逐段补全") } footer: {
            Text("只读取本机正文；每次最多 3 章、96 KiB。候选确认后收录，同名与别名不自动合并。")
        }
    }
    private func candidatesSection(_ scope: CharacterScope) -> some View {
        Section {
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.name).font(.headline)
                    ForEach(candidate.facts) { fact in
                        Text(fact.text)
                        DisclosureGroup("出处 · 第 \(fact.chapter + 1) 章") { Text(fact.quote).font(.footnote) }
                    }
                    Button("确认收录为独立人物") {
                        do { try store.accept(candidate, scope: scope); candidates.removeAll { $0.id == candidate.id } }
                        catch { message = error.localizedDescription }
                    }
                    Button("丢弃候选", role: .destructive) { candidates.removeAll { $0.id == candidate.id } }
                }
            }
        } header: { Text("待确认候选 · \(candidates.count)") }
    }
    private func manualSection(_ scope: CharacterScope) -> some View {
        Section {
            if !chapters.isEmpty {
                DisclosureGroup("手工添加人物与事实") {
                    Picker("出处章节", selection: $manualChapter) { ForEach(chapters, id: \.index) { Text($0.title).tag($0.index) } }
                    TextField("原文人名／称谓", text: $manualName)
                    TextField("事实描述", text: $manualText)
                    TextField("连续原文证据（10–150 字）", text: $manualQuote)
                    Button("校验原文并收录") { addManual(scope) }.disabled(progress != nil)
                }
            }
        }
    }
    private func cancel() { token = UUID(); generation?.cancel(); generation = nil; progress = nil }
    private func loadScope() async {
        cancel(); scopeReady = false; identities = [:]; current = nil; target = nil; plan = nil; candidates = []; message = nil
        guard confirmed, let book = books.first(where: { $0.key == currentBook }) else { return }
        let snapshot = loadID
        do {
            let loaded = try await CharacterVolumeLoader.load(book, settings: settings)
            try Task.checkCancellation(); guard loadID == snapshot else { return }
            if book.key == initialBook, let readingIdentity, loaded.source.identity != readingIdentity { throw CharacterLexiconError.changed }
            current = loaded; identities[book.key] = loaded.source.identity
            for key in eligibleBooks where key != book.key {
                try Task.checkCancellation()
                guard let previous = books.first(where: { $0.key == key }) else { continue }
                if let value = try? await CharacterVolumeLoader.load(previous, settings: settings) {
                    guard !Task.isCancelled, loadID == snapshot else { return }; identities[key] = value.source.identity
                }
            }
            if !eligibleBooks.contains(targetBook) { targetBook = currentBook }
            try Task.checkCancellation(); guard loadID == snapshot else { return }
            scopeReady = true
        } catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func loadTarget() async {
        cancel(); target = nil; plan = nil; candidates = []; chapters = []
        guard confirmed, scopeReady, eligibleBooks.contains(targetBook), let book = books.first(where: { $0.key == targetBook }) else { return }
        let snapshot = targetID
        do {
            let value = targetBook == currentBook ? current : try await CharacterVolumeLoader.load(book, settings: settings)
            try Task.checkCancellation(); guard targetID == snapshot, let value else { return }
            target = value; identities[targetBook] = value.source.identity; start = 0
        } catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func prepare() async {
        cancel(); plan = nil; chapters = []; candidates = []
        guard let scope, let target, upper > 0, start >= 0, start < upper else { return }
        let snapshot = rangeID, book = targetBook
        do {
            let values = try await target.source.load(start..<min(start + 3, upper))
            try Task.checkCancellation(); guard rangeID == snapshot, self.scope == scope else { return }
            plan = try .init(scope: scope, book: book, identity: target.source.identity, chapters: values)
            chapters = values; manualChapter = values.first?.index ?? 0
        } catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func generate(_ plan: CharacterExtractionPlan) {
        cancel(); message = nil; candidates = []; progress = "准备生成…"
        let snapshot = token
        generation = Task {
            do {
                let values = try await CharacterGenerator.generate(plan: plan, ai: ai) { i, count in progress = "正在生成 \(i)/\(count)…" }
                guard !Task.isCancelled, token == snapshot, scope == plan.scope else { return }
                candidates = values
                if values.isEmpty { message = "此范围未找到有充分原文证据的人物。" }
            } catch is CancellationError {} catch { if token == snapshot { message = error.localizedDescription } }
            if token == snapshot { progress = nil; generation = nil }
        }
    }
    private func addManual(_ scope: CharacterScope) {
        guard let chapter = chapters.first(where: { $0.index == manualChapter }), let target else { return }
        let range = (chapter.text as NSString).range(of: manualQuote, options: .literal)
        guard range.location != NSNotFound else { message = CharacterLexiconError.evidence.localizedDescription; return }
        let fact = CharacterFact(book: targetBook, identity: target.source.identity, chapter: chapter.index, offset: range.location,
                                 name: manualName, text: manualText, quote: manualQuote, manual: true, chapterTitle: chapter.title)
        do { try store.accept(.init(facts: [fact]), scope: scope); manualName = ""; manualText = ""; manualQuote = "" }
        catch { message = error.localizedDescription }
    }
}

@MainActor
private struct CharacterCardView: View {
    let id: String
    let scope: CharacterScope
    let books: [LibraryBook]
    @ObservedObject var store: CharacterLexiconStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var editing: CharacterFact?
    private var person: VisibleCharacter? { scope.visible(store.entities).first { $0.id == id } }
    var body: some View {
        List {
            if let person {
                Section {
                    Text(person.name).font(.title2)
                    if !person.aliases.isEmpty { Text("已知别名：" + person.aliases.joined(separator: "、")) }
                    if let first = person.facts.first { Text("首次记录：\(bookTitle(first)) · 第 \(first.chapter + 1) 章").font(.footnote) }
                    ForEach(person.facts) { fact in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fact.text)
                            if fact.manual { Text("手工修订").font(.caption).foregroundStyle(.secondary) }
                            Menu("修改此条事实") {
                                Button("编辑描述") { editing = fact }
                                Button("拆分为独立人物") { perform { try store.split(fact: fact.id, from: id, scope: scope) } }
                                    .disabled(person.facts.count < 2)
                                Button("删除事实", role: .destructive) { perform { try store.remove(fact: fact.id, entity: id, scope: scope) } }
                            }
                        }
                    }
                }
                Section {
                    DisclosureGroup("出处 · \(person.facts.count) 条") {
                        ForEach(person.facts) { fact in evidenceLink(fact) }
                    }
                    NavigationLink("查看全部出处") {
                        List { ForEach(person.facts) { fact in evidenceLink(fact) } }.navigationTitle("全部出处")
                    }
                }
                Section {
                    Menu("合并到另一人物（需自行确认身份）") {
                        ForEach(scope.visible(store.entities).filter { $0.id != id }) { target in
                            Button(target.name + " · " + (target.facts.first.map { bookTitle($0) + " 第 \($0.chapter + 1) 章" } ?? "")) { perform { try store.merge(id, into: target.id, scope: scope); dismiss() } }
                        }
                    }
                    Text("别名来自各条可见事实，不因合并而展示后卷才出现的真名。AI 描述仍可能有误，请核对出处。").font(.footnote)
                }
            } else { Text("此人物在当前范围不可见，或已被合并／移除。") }
            if let error { Text(error).foregroundStyle(NoveliaStyle.danger) }
        }
        .navigationTitle(person?.name ?? "人物卡")
        .sheet(item: $editing) { fact in
            CharacterFactEditor(fact: fact) { text in try store.edit(fact: fact.id, entity: id, text: text, scope: scope) }
        }
    }
    private func bookTitle(_ fact: CharacterFact) -> String { books.first { $0.key == fact.book }?.title ?? "缺失的卷" }
    private func evidenceLink(_ fact: CharacterFact) -> some View {
        NavigationLink {
            CharacterEvidenceView(fact: fact, scope: scope, book: books.first { $0.key == fact.book })
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(bookTitle(fact)) · 第 \(fact.chapter + 1) 章")
                Text(fact.quote).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

@MainActor
private struct CharacterFactEditor: View {
    let fact: CharacterFact
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        NavigationView {
            Form {
                Section("事实描述") { TextEditor(text: $text).frame(minHeight: 100) }
                Section("原文依据（保留）") { Text(fact.quote) }
                Button("保存手工修订") { do { try save(text); dismiss() } catch { self.error = error.localizedDescription } }
                if let error { Text(error).foregroundStyle(NoveliaStyle.danger) }
            }.navigationTitle("修订人物事实")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .onAppear { text = fact.text }
        }
    }
}

/// 读取副本定位证据，不导航阅读器、不写进度；返回时仍停留在人物卡或出处列表。
@MainActor
private struct CharacterEvidenceView: View {
    let fact: CharacterFact
    let scope: CharacterScope
    let book: LibraryBook?
    @EnvironmentObject private var settings: ReaderSettings
    @State private var chapter: RecapChapter?
    @State private var fallback = false
    @State private var error: String?
    var body: some View {
        Group {
            if let chapter, fallback {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("版本或锚点已变化，已打开对应同名章节，未定位旧引文。").font(.footnote).foregroundStyle(.secondary)
                        Text(chapter.text).textSelection(.enabled)
                    }.padding()
                }
            } else if let chapter {
                RecapEvidenceView(chapter: chapter, event: .init(chapter: fact.chapter, title: chapter.title, summary: fact.text, quote: fact.quote, offset: fact.offset))
            } else if let error { Text(error).padding() }
            else { ProgressView("读取出处…") }
        }
        .navigationTitle("出处原文")
        .task {
            do {
                guard scope.permits(fact), let book else { throw CharacterLexiconError.missing }
                let value = try await CharacterVolumeLoader.load(book, settings: settings)
                guard fact.chapter >= 0, fact.chapter < value.source.currentChapter else { throw CharacterLexiconError.changed }
                let values = try await value.source.load(fact.chapter..<(fact.chapter + 1))
                try Task.checkCancellation()
                guard let chapter = values.first else { throw CharacterLexiconError.changed }
                let exact = value.source.identity == fact.identity && fact.offset >= 0 && fact.offset <= chapter.text.utf16.count
                    && fact.quote.utf16.count <= chapter.text.utf16.count - fact.offset
                    && (chapter.text as NSString).substring(with: NSRange(location: fact.offset, length: fact.quote.utf16.count)) == fact.quote
                if !exact {
                    guard fact.chapterTitle == chapter.title,
                          fact.book != scope.currentBook || fact.chapter < value.boundary else { throw CharacterLexiconError.changed }
                    fallback = true
                }
                self.chapter = chapter
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
