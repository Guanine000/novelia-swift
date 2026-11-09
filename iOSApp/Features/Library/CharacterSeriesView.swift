// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 生成/更新均由用户触发。范围、逐卷进度和缺失文件在发送前展示，完整章节才提交检查点。
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
    @EnvironmentObject private var library: LibraryStateStore
    @State private var order = [String]()
    @State private var currentBook = ""
    @State private var scanSeries = false
    @State private var requestLimit = 64
    @State private var query = ""
    @State private var ready = false
    @State private var identities: [String: String] = [:]
    @State private var boundaries: [String: Int] = [:]
    @State private var statuses: [String: String] = [:]
    @State private var message: String?
    @State private var progress: String?
    @State private var generation: Task<Void, Never>?
    @State private var token = UUID()
    private var confirmed: Bool { !order.isEmpty && store.order(work: workID) == order }
    private var eligibleBooks: [String] {
        guard let index = order.firstIndex(of: currentBook) else { return [] }
        return Array(order.prefix(index + 1))
    }
    private var selectedBooks: [String] { scope?.booksForScan(series: scanSeries) ?? [] }
    private var scope: CharacterScope? {
        guard confirmed, ready else { return nil }
        return .init(work: workID, volumes: order, currentBook: currentBook, currentChapter: boundaries[currentBook] ?? 0,
            identities: identities, readBoundaries: boundaries)
    }
    private var visible: [VisibleCharacter] { scope.map { $0.visible(store.entities, query: query) } ?? [] }
    private var loadID: String { currentBook + "|" + order.joined(separator: ",") + "|\(settings.projectionRevision)|\(confirmed)" }
    private var actionID: String { loadID + "|\(scanSeries)" }
    private func title(_ key: String) -> String { books.first { $0.key == key }?.title ?? "缺失的卷" }
    private func processed(_ key: String) -> Int {
        guard let scope, let identity = identities[key],
              let signature = try? CharacterAutomaticUpdater.signature(identity: identity, scope: scope, configuration: ai.configuration) else { return 0 }
        return store.scannedThrough(work: workID, book: key, signature: signature)
    }
    private var remainingChapters: Int { selectedBooks.reduce(0) { $0 + max(0, (boundaries[$1] ?? 0) - processed($1)) } }
    private var hasHistory: Bool { selectedBooks.contains { processed($0) > 0 } }

    var body: some View {
        List {
            Section {
                ForEach(order, id: \.self) { key in Text(title(key)) }
                    .onMove { offsets, destination in cancel(); order.move(fromOffsets: offsets, toOffset: destination) }
                Button(confirmed ? "卷序已确认" : "确认以上卷序") {
                    do { try store.confirmOrder(work: workID, volumes: order) }
                    catch { message = error.localizedDescription }
                }.disabled(confirmed || progress != nil)
            } header: { Text("系列卷序") } footer: {
                Text("卷序决定前后关系；各卷仅使用自己的保存位置之前的完整章节。无进度不扫描，当前章与后卷排除，跳读过的章节无法逐章识别。")
            }
            if confirmed {
                Section {
                    Picker("当前阅读书籍", selection: $currentBook) {
                        ForEach(order, id: \.self) { Text(title($0)).tag($0) }
                    }.disabled(progress != nil)
                    Picker("生成与更新范围", selection: $scanSeries) {
                        Text("仅本书").tag(false)
                        Text("系列所有书籍").tag(true)
                    }.pickerStyle(.segmented).disabled(progress != nil)
                    if !ready { ProgressView("检查本地书籍与阅读位置…") }
                    ForEach(selectedBooks, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(key))
                            if let status = statuses[key] { Text(status).font(.caption).foregroundStyle(.secondary) }
                            else {
                                let upper = boundaries[key] ?? 0
                                let done = min(processed(key), upper)
                                Text(upper > done ? "待处理第 \(done + 1)–\(upper) 章；已处理 \(done) 章" : "已更新到当前可用阅读位置")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if scanSeries, eligibleBooks.count < order.count {
                        Text("后续 \(order.count - eligibleBooks.count) 本未纳入；系列所有书籍仍受当前阅读卷和各卷进度限制。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if scope != nil {
                        Button(hasHistory || !store.entities.filter({ $0.work == workID }).isEmpty ? "更新人物卡" : "生成人物卡") { generate() }
                            .disabled(progress != nil || !ai.isReadyForGeneration)
                        Text("本轮新增 \(remainingChapters) 章，最多\(requestLimit)次新请求，每次输出上限 \(ai.configuration.maximumOutputTokens) tokens；发送至 \((try? ai.configuration.endpoint().host) ?? "所配置接口")，可能产生费用。匹配缓存不产生请求。")
                            .font(.footnote)
                    }
                    DisclosureGroup("用量上限") {
                        Picker("本轮新请求上限", selection: $requestLimit) {
                            ForEach([32, 64, 128, 256], id: \.self) { Text("\($0)次").tag($0) }
                        }.disabled(progress != nil)
                    }
                    if !ai.isReadyForGeneration { Text("请先在AI阅读辅助中配置接口、模型和密钥并启用服务。").font(.footnote) }
                } header: { Text("自动生成人物卡") } footer: {
                    Text("点击后按卷序分批处理并自动保存人物卡，不自动下载缺失书籍。完成的章节保存检查点，取消或失败后点击更新可继续；当前未完成章节不保存半成品。同名不直接合并，身份关联和疑点标为待核实。")
                }
                if let scope {
                    Section {
                        TextField("按当前可见人名／别名查找", text: $query)
                        ForEach(visible) { person in
                            NavigationLink {
                                CharacterCardView(id: person.id, initialScope: scope, books: books,
                                    workTitle: library.series.series[workID]?.name ?? "", includeSeries: scanSeries, requestLimit: requestLimit, store: store, ai: ai)
                            } label: {
                                HStack(spacing: 12) {
                                    CharacterPortraitImage(store: store, id: person.id, scope: scope, name: person.name, compact: true)
                                        .frame(width: 48, height: 60).clipShape(RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 4) {
                                    Text(person.name)
                                    if !person.aliases.isEmpty { Text(person.aliases.joined(separator: "、")).font(.caption) }
                                    let count = person.facts.filter { $0.needsReview == true }.count
                                    if count > 0 { Text("\(count)条待核实").font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                        if visible.isEmpty { Text("当前阅读范围内暂无人物卡，点击生成即可建立。").foregroundStyle(.secondary) }
                    } header: { Text("人物卡") }
                }
            }
            if let progress {
                Section { HStack { ProgressView(); Text(progress) }; Button("暂停") { cancel(); message = "已暂停，完成的章节已保存。点击更新继续。" } }
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("跨卷人物词条")
        .toolbar { ToolbarItem(placement: .compatTopBarTrailing) { EditButton().disabled(progress != nil) } }
        .onAppear {
            guard order.isEmpty else { return }
            let saved = store.order(work: workID).filter { key in books.contains { $0.key == key } }
            let remaining = books.filter { !saved.contains($0.key) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.key)
            order = saved + remaining; query = initialQuery
            currentBook = order.contains(initialBook ?? "") ? initialBook! : order.first ?? ""
        }
        .task(id: loadID) { await loadScope() }
        .onValueChange(of: scanSeries) { _, _ in cancel(); message = nil }
        .onValueChange(of: ai.configuration) { _, _ in cancel(); message = nil }
        .onDisappear { cancel() }
    }
    private func cancel() { token = UUID(); generation?.cancel(); generation = nil; progress = nil }
    private func loadScope(cancelGeneration: Bool = true) async {
        if cancelGeneration { cancel() }
        ready = false; identities = [:]; boundaries = [:]; statuses = [:]; message = nil
        guard confirmed else { return }
        let snapshot = loadID
        for key in eligibleBooks {
            guard let book = books.first(where: { $0.key == key }) else { continue }
            do {
                let value = try await CharacterVolumeLoader.load(book, settings: settings)
                try Task.checkCancellation(); guard loadID == snapshot else { return }
                if key == initialBook, let readingIdentity, value.source.identity != readingIdentity { throw CharacterLexiconError.changed }
                identities[key] = value.source.identity
                let boundary = key == initialBook ? readingBoundary ?? value.boundary : value.boundary
                boundaries[key] = min(max(0, boundary), value.source.currentChapter)
                if boundaries[key] == 0 { statuses[key] = "没有可扫描的已读完整章节；暂不处理。" }
            } catch is CancellationError { return }
            catch {
                guard loadID == snapshot, !Task.isCancelled else { return }
                statuses[key] = "本轮跳过：" + error.localizedDescription
            }
        }
        guard loadID == snapshot, !Task.isCancelled else { return }
        ready = true
    }
    private func generate() {
        cancel(); message = nil; progress = "准备生成…"
        let snapshot = token, selection = selectedBooks, identity = actionID, config = ai.configuration, limit = requestLimit
        generation = Task {
            var requests = 0, completed = 0
            do {
                await loadScope(cancelGeneration: false)
                try Task.checkCancellation()
                guard snapshot == token, actionID == identity, ai.configuration == config, let scope else { throw CancellationError() }
                let result = try await CharacterBookUpdater.run(books: books, scope: scope, selection: selection, settings: settings,
                    store: store, ai: ai, limit: limit) { text in if snapshot == token { progress = text } }
                completed = result.completed; requests = result.requests
                guard snapshot == token, !Task.isCancelled else { return }
                message = "本轮完成\(completed)章，新增\(requests)次请求。人物卡已保存；缺失或无进度的书籍未纳入。疑点可在卡片中核实。"
            } catch is CancellationError {} catch {
                guard snapshot == token, !Task.isCancelled else { return }
                message = error.localizedDescription + " 完成的章节已保存，更新可继续。"
            }
            if snapshot == token { progress = nil; generation = nil }
        }
    }
}

@MainActor
private struct CharacterCardView: View {
    let id: String
    let initialScope: CharacterScope
    let books: [LibraryBook]
    let workTitle: String
    let includeSeries: Bool
    let requestLimit: Int
    @ObservedObject var store: CharacterLexiconStore
    @ObservedObject var ai: ReadingAIStore
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sizeCategory) private var sizeCategory
    @State private var refreshedScope: CharacterScope?
    @State private var error: String?
    @State private var editing: CharacterFact?
    @State private var managingPortrait = false
    @State private var importingPortrait = false
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var showingPortrait = false
    @State private var updating = false
    @State private var updateTask: Task<Void, Never>?
    @State private var updateMessage: String?
    @State private var confirmingDelete = false
    @State private var updateStarted = Date()
    private var scope: CharacterScope { refreshedScope ?? initialScope }
    private var person: VisibleCharacter? { scope.visible(store.entities).first { $0.id == id } }
    private var confirmedFacts: [CharacterFact] { person?.facts.filter { $0.needsReview != true } ?? [] }
    private var pending: [CharacterFact] { person?.facts.filter { $0.needsReview == true } ?? [] }
    private var portrait: CharacterPortrait? { store.portrait(for: id, scope: scope) }
    private var summary: String {
        let identity = confirmedFacts.last { $0.category == "身份" }?.text
        let goal = confirmedFacts.last { $0.category == "目标" }?.text
        let lines = [identity, goal].compactMap { $0 }
        return lines.isEmpty ? confirmedFacts.first?.text ?? "当前信息仍待核实，可展开下方记录查看依据。" : lines.joined(separator: "。")
    }
    private var caughtUp: Bool {
        let books = scope.booksForScan(series: includeSeries)
        guard !books.isEmpty else { return false }
        return books.allSatisfy { book in
            guard let identity = scope.identities[book], let boundary = scope.readBoundaries?[book], boundary > 0,
                  let signature = try? CharacterAutomaticUpdater.signature(identity: identity, scope: scope, configuration: ai.configuration) else { return false }
            return store.scannedThrough(work: scope.work, book: book, signature: signature) >= boundary
        }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let person {
                    hero(person)
                    if !confirmedFacts.filter({ !["关系", "经历"].contains($0.category ?? "经历") }).isEmpty {
                        panel("人物档案", icon: "doc.text") {
                            ForEach(["身份", "外貌", "性格", "能力", "目标"], id: \.self) { category in
                                let facts = confirmedFacts.filter { $0.category == category }
                                if !facts.isEmpty { archiveRow(category, facts: facts) }
                            }
                        }
                    }
                    let relations = confirmedFacts.filter { $0.category == "关系" }
                    if !relations.isEmpty {
                        panel("人物关系", icon: "person.2") {
                            ForEach(relations) { fact in relationshipRow(fact) }
                        }
                    }
                    let events = confirmedFacts.filter { ($0.category ?? "经历") == "经历" }
                    if !events.isEmpty {
                        panel("重要经历", icon: "flag") {
                            ForEach(events) { fact in eventRow(fact) }
                        }
                    }
                    if !pending.isEmpty {
                        disclosureCard("待核实 · \(pending.count)条", icon: "circle.fill", amber: true) {
                            ForEach(pending) { fact in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(fact.text).font(.body)
                                    evidenceLink(fact)
                                    HStack {
                                        Button("核对后确认此条") { perform { try store.confirm(fact: fact.id, entity: id, scope: scope) } }
                                        Spacer()
                                        Menu { factActions(fact) } label: { Image(systemName: "ellipsis") }
                                    }.font(.footnote)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                    disclosureCard("出处 · \(person.facts.count)条", icon: "bookmark") {
                        ForEach(person.facts) { fact in evidenceLink(fact).padding(.vertical, 5) }
                        NavigationLink("查看全部出处") {
                            List { ForEach(person.facts) { fact in evidenceLink(fact) } }.navigationTitle("全部出处")
                        }.padding(.vertical, 8)
                    }
                } else { Text("此人物在当前阅读范围不可见，或已被合并／移除。").padding(.vertical, 40) }
                if let updateMessage { Text(updateMessage).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                if let error { Text(error).font(.footnote).foregroundStyle(NoveliaStyle.danger).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("人物卡").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarTrailing) {
                Menu {
                    Button("编辑角色形象") { managingPortrait = true }
                    Menu("合并到另一人物") {
                        ForEach(scope.visible(store.entities).filter { $0.id != id }) { target in
                            Button(target.name + " · " + (target.facts.first.map { bookTitle($0) + " 第 \($0.chapter + 1) 章" } ?? "")) {
                                perform { try store.merge(id, into: target.id, scope: scope); dismiss() }
                            }
                        }
                    }
                    Divider()
                    Button("删除此人物", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis").foregroundStyle(NoveliaStyle.brandGreen) }
            }
        }
        .safeAreaInset(edge: .bottom) { updateBar }
        .sheet(item: $editing) { fact in
            CharacterFactEditor(fact: fact) { text in try store.edit(fact: fact.id, entity: id, text: text, scope: scope) }
        }
        .sheet(isPresented: $managingPortrait) { portraitEditor }
        .alert("删除「\(person?.name ?? "")」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                if (try? store.removeEntity(id, scope: scope)) != nil { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该人物卡及其全部事实会被删除，并在当前正文版本记为已否决，重新扫描不会自动恢复。")
        }
        .sheet(isPresented: $showingPortrait) {
            NavigationView {
                CharacterPortraitImage(store: store, id: id, scope: scope, name: person?.name ?? "", compact: false, fits: true)
                    .padding().navigationTitle("角色形象")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showingPortrait = false } } }
            }
        }
        .onValueChange(of: ai.configuration) { _, _ in updateTask?.cancel() }
        .onDisappear { importTask?.cancel(); updateTask?.cancel() }
    }
    private func hero(_ person: VisibleCharacter) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 13) {
                Image(systemName: "leaf").rotationEffect(.degrees(-35)).font(.title3).foregroundStyle(NoveliaStyle.brandGreen.opacity(0.7))
                ZStack(alignment: .bottomTrailing) {
                    Button { if portrait == nil { managingPortrait = true } else { showingPortrait = true } } label: {
                        if portrait != nil {
                            CharacterPortraitImage(store: store, id: id, scope: scope, name: person.name, compact: false)
                                .frame(width: 70, height: 88).clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(NoveliaStyle.brandGreen.opacity(0.4), lineWidth: 1))
                        } else {
                            Text(String(person.name.prefix(1))).font(.system(size: 29, weight: .medium, design: .serif))
                                .foregroundStyle(NoveliaStyle.ink).frame(width: 62, height: 62)
                                .background(NoveliaStyle.card.opacity(0.55)).clipShape(Circle())
                                .overlay(Circle().stroke(NoveliaStyle.brandGreen, lineWidth: 1))
                                .padding(3).overlay(Circle().stroke(NoveliaStyle.brandGreen.opacity(0.5), lineWidth: 1))
                        }
                    }.buttonStyle(.plain).accessibilityLabel(portrait == nil ? "添加角色形象" : "查看角色形象")
                    Button { managingPortrait = true } label: {
                        Image(systemName: "camera.fill").font(.system(size: 10)).padding(6)
                            .foregroundStyle(NoveliaStyle.brandGreen).background(NoveliaStyle.card).clipShape(Circle())
                    }.buttonStyle(.plain).offset(x: 7, y: 3).accessibilityLabel("编辑角色形象")
                }
                Image(systemName: "leaf").rotationEffect(.degrees(35)).scaleEffect(x: -1, y: 1).font(.title3).foregroundStyle(NoveliaStyle.brandGreen.opacity(0.7))
            }
            Text(person.name).font(.system(.largeTitle, design: .serif).weight(.semibold)).foregroundStyle(NoveliaStyle.ink)
            Text(workTitle.isEmpty ? "人物档案" : "《\(workTitle)》 · 人物档案").font(.subheadline).foregroundStyle(.secondary)
            if !person.aliases.isEmpty { Text("已知别名：" + person.aliases.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
            Text(scope.currentChapter > 0 ? "截至第\((scope.volumes.firstIndex(of: scope.currentBook) ?? 0) + 1)卷 · 第\(scope.currentChapter)章" : "当前卷尚无已读完整章节")
                .font(.caption).padding(.horizontal, 12).padding(.vertical, 4).background(NoveliaStyle.ink.opacity(0.06)).clipShape(Capsule())
            HStack(spacing: 12) {
                Rectangle().frame(width: 26, height: 0.6)
                Text(updating ? "正在更新人物资料…" : caughtUp ? "已更新到当前阅读位置" : "仅展示当前已知资料").font(.subheadline.weight(.medium))
                Rectangle().frame(width: 26, height: 0.6)
            }.foregroundStyle(NoveliaStyle.brandGreen).padding(.top, 1)
            Text(summary).font(.system(.body, design: .serif)).lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11)
        }.padding(.bottom, 3)
    }
    private func panel<Content: View>(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(title).font(.system(.title3, design: .serif).weight(.semibold)) } icon: {
                Image(systemName: icon).font(.title3).foregroundStyle(NoveliaStyle.brandGreen)
            }.accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(NoveliaStyle.card.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(NoveliaStyle.ink.opacity(0.025), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 3)
    }
    private func archiveRow(_ category: String, facts: [CharacterFact]) -> some View {
        VStack(spacing: 0) {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 8) { fieldTag(category); Text(facts.last?.text ?? ""); evidencePill(facts, category: category) }.padding(.vertical, 9)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    fieldTag(category).frame(width: 47)
                    Text(facts.last?.text ?? "").font(.system(.body, design: .serif)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    evidencePill(facts, category: category)
                }.padding(.vertical, 9)
            }
            Divider().opacity(0.45)
        }.contextMenu { if let fact = facts.last { factActions(fact) } }
    }
    private func fieldTag(_ text: String) -> some View {
        Text(text).font(.system(.subheadline, design: .serif)).padding(.vertical, 3).frame(maxWidth: .infinity)
            .background(NoveliaStyle.ink.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 5))
    }
    private func evidencePill(_ facts: [CharacterFact], category: String) -> some View {
        NavigationLink {
            List { ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 8) { Text(fact.text); evidenceLink(fact); Menu("修改此条事实") { factActions(fact) } }
            } }.navigationTitle(category + " · 出处")
        } label: {
            HStack(spacing: 3) { Text("\(facts.count)条出处"); Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
                .font(.caption2).foregroundStyle(NoveliaStyle.muted).padding(.horizontal, 7).padding(.vertical, 5)
                .background(NoveliaStyle.ink.opacity(0.045)).clipShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(category + "出处，\(facts.count)条")
    }
    private func relationshipRow(_ fact: CharacterFact) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(fact.relatedName ?? "关系").font(.system(.body, design: .serif)).frame(width: 57, alignment: .leading)
            HStack(spacing: 0) {
                Circle().stroke(NoveliaStyle.brandGreen, lineWidth: 1).frame(width: 5, height: 5)
                Rectangle().fill(NoveliaStyle.brandGreen).frame(width: 17, height: 1)
                Circle().stroke(NoveliaStyle.brandGreen, lineWidth: 1).frame(width: 5, height: 5)
            }.padding(.top, 8).accessibilityHidden(true)
            Text(fact.text).font(.system(.body, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink { List { evidenceLink(fact); Menu("修改此条事实") { factActions(fact) } }.navigationTitle("关系出处") } label: {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.accessibilityLabel("查看关系出处")
        }.padding(.vertical, 9).overlay(alignment: .bottom) { Divider().opacity(0.45) }
            .contextMenu { factActions(fact) }
    }
    private func eventRow(_ fact: CharacterFact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) { Circle().fill(NoveliaStyle.brandGreen).frame(width: 6, height: 6); Rectangle().fill(NoveliaStyle.brandGreen.opacity(0.25)).frame(width: 1, height: 28) }.padding(.top, 7).accessibilityHidden(true)
            NavigationLink { List { evidenceLink(fact); Menu("修改此条事实") { factActions(fact) } }.navigationTitle("经历出处") } label: {
                Text("第\((scope.volumes.firstIndex(of: fact.book) ?? 0) + 1)卷 · 第\(fact.chapter + 1)章").font(.caption)
                    .foregroundStyle(NoveliaStyle.ink).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(NoveliaStyle.ink.opacity(0.045)).clipShape(Capsule())
            }.buttonStyle(.plain)
            Text(fact.text).font(.system(.subheadline, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 8).contextMenu { factActions(fact) }
    }
    private func disclosureCard<Content: View>(_ title: String, icon: String, amber: Bool = false, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8, content: content).padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(amber ? .system(size: 9) : .title3).foregroundStyle(amber ? Color.orange.opacity(0.75) : NoveliaStyle.brandGreen)
                Text(title).font(.system(.body, design: .serif).weight(.medium)).foregroundStyle(NoveliaStyle.ink)
            }
        }.padding(14).background(NoveliaStyle.card.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 13))
    }
    private var updateBar: some View {
        VStack(spacing: 0) {
            if updating {
                Button { updateTask?.cancel() } label: {
                    VStack(spacing: 3) {
                        HStack { ProgressView().tint(.white); Text("暂停更新") }
                        // 一次高分块生成可能要几分钟，秒表能区分"在跑"和"真卡死"。
                        TimelineView(.periodic(from: updateStarted, by: 1)) { context in
                            Text((updateMessage ?? "正在处理新增章节…") + " · 已等待\(Int(max(0, context.date.timeIntervalSince(updateStarted))))秒").font(.caption)
                        }
                    }
                        .frame(maxWidth: .infinity).padding(.vertical, 12).foregroundStyle(.white)
                }.buttonStyle(.plain).background(NoveliaStyle.brandGreen).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Button { update() } label: {
                    VStack(spacing: 3) {
                        Label("更新人物卡", systemImage: "arrow.clockwise").font(.system(.title3, design: .serif).weight(.medium))
                        Text(ai.isReadyForGeneration ? "仅处理新增已读章节 · \(includeSeries ? "系列" : "本书")" : "请先配置并启用AI服务").font(.caption)
                    }.frame(maxWidth: .infinity).padding(.vertical, 11).foregroundStyle(.white)
                }.buttonStyle(.plain).background(NoveliaStyle.brandGreen).clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(!ai.isReadyForGeneration || person == nil || importing)
            }
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6).background(NoveliaStyle.paper.opacity(0.98))
    }
    private var portraitEditor: some View {
        NavigationView {
            Form {
                Section {
                    CharacterPortraitImage(store: store, id: id, scope: scope, name: person?.name ?? "", compact: false, fits: true).frame(height: 200)
                    CompatPhotosPickerButton(isDisabled: importing, onData: importPortrait) {
                        Label(portrait == nil ? "从相册添加角色形象" : "从相册更换角色形象", systemImage: "photo")
                    }
                    Button { importingPortrait = true } label: { Label("从文件选择角色图片", systemImage: "folder") }.disabled(importing)
                    if portrait != nil {
                        Button("移除角色形象", role: .destructive) { perform { try store.setPortrait(nil, entity: id, scope: scope) } }.disabled(importing)
                    }
                    if importing { ProgressView("正在处理角色图片…") }
                } footer: {
                    Text("仅用于展示，不发送给AI；随人物卡WebDAV选项同步。图片缩小并移除原图元数据，以添加时的阅读位置为可见起点。图片内容请自行避免剧透。")
                }
                if let error { Text(error).foregroundStyle(NoveliaStyle.danger) }
            }.navigationTitle("角色形象").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { managingPortrait = false } } }
                .fileImporter(isPresented: $importingPortrait, allowedContentTypes: [.image]) { result in
                    do {
                        let url = try result.get()
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                        guard size <= 20 * 1_024 * 1_024 else { throw CharacterPortraitImportError.invalid }
                        importPortrait(try Data(contentsOf: url))
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
    private func importPortrait(_ data: Data) {
        importTask?.cancel(); importing = true; error = nil
        importTask = Task {
            defer { importing = false }
            let result = await Task.detached(priority: .userInitiated) { CharacterPortraitCodec.jpeg(data, maximumPixels: 1_024) }.value
            guard !Task.isCancelled else { return }
            do { guard let result else { throw CharacterPortraitImportError.invalid }; try store.setPortrait(result, entity: id, scope: scope) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func update() {
        updateTask?.cancel(); updating = true; error = nil; updateStarted = Date(); updateMessage = nil
        updateTask = Task {
            defer { updating = false }
            do {
                var identities = [String: String](), boundaries = [String: Int]()
                for key in initialScope.booksForScan(series: true) {
                    guard let book = books.first(where: { $0.key == key }) else { continue }
                    if let value = try? await CharacterVolumeLoader.load(book, settings: settings) {
                        try Task.checkCancellation(); identities[key] = value.source.identity; boundaries[key] = value.boundary
                    }
                }
                let fresh = CharacterScope(work: initialScope.work, volumes: initialScope.volumes, currentBook: initialScope.currentBook,
                    currentChapter: boundaries[initialScope.currentBook] ?? 0, identities: identities, readBoundaries: boundaries)
                try Task.checkCancellation(); refreshedScope = fresh
                let result = try await CharacterBookUpdater.run(books: books, scope: fresh, selection: fresh.booksForScan(series: includeSeries),
                    settings: settings, store: store, ai: ai, limit: requestLimit) { updateMessage = $0 }
                updateMessage = "完成\(result.completed)章，新增\(result.requests)次请求。缺书或无进度的卷未纳入。"
            } catch is CancellationError { updateMessage = "已暂停，完成章节已保存。" }
            catch { self.error = error.localizedDescription + " 完成章节已保存，可继续更新。" }
        }
    }
    @ViewBuilder private func factActions(_ fact: CharacterFact) -> some View {
        Button("编辑描述") { editing = fact }
        Button("拆分为独立人物") { perform { try store.split(fact: fact.id, from: id, scope: scope) } }.disabled((person?.facts.count ?? 0) < 2)
        Button("删除事实", role: .destructive) { perform { try store.remove(fact: fact.id, entity: id, scope: scope) } }
    }
    private func bookTitle(_ fact: CharacterFact) -> String { books.first { $0.key == fact.book }?.title ?? "缺失的卷" }
    private func evidenceLink(_ fact: CharacterFact) -> some View {
        NavigationLink { CharacterEvidenceView(fact: fact, scope: scope, books: books) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(bookTitle(fact)) · 第\(fact.chapter + 1)章").font(.caption).foregroundStyle(.secondary)
                Text(fact.quote).font(.footnote)
                if let anchor = fact.attribution {
                    Text("人名关联依据 · \(books.first { $0.key == (anchor.book ?? fact.book) }?.title ?? "缺失的卷") · 第\(anchor.chapter + 1)章：\(anchor.quote)").font(.footnote)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

/// 主列表与人物详情共用同一更新执行路径，防止界面改版改变范围、请求预算或检查点契约。
@MainActor
private enum CharacterBookUpdater {
    static func run(books: [LibraryBook], scope: CharacterScope, selection: [String], settings: ReaderSettings,
                    store: CharacterLexiconStore, ai: ReadingAIStore, limit: Int,
                    progress: (String) -> Void) async throws -> (completed: Int, requests: Int) {
        let config = ai.configuration
        guard store.order(work: scope.work) == scope.volumes else { throw CharacterLexiconError.scope }
        guard ai.isReadyForGeneration else { throw ai.configuration.isEnabled ? ReadingAIError.missingKey : ReadingAIError.disabled }
        var requests = 0, completed = 0
        for key in selection {
            try Task.checkCancellation()
            guard ai.configuration == config else { throw CancellationError() }
            guard let book = books.first(where: { $0.key == key }), let expected = scope.identities[key], let upper = scope.readBoundaries?[key], upper > 0 else { continue }
            let signature = try CharacterAutomaticUpdater.signature(identity: expected, scope: scope, configuration: config)
            let lower = store.scannedThrough(work: scope.work, book: key, signature: signature)
            guard lower < upper else { continue }
            let value = try await CharacterVolumeLoader.load(book, settings: settings)
            guard value.source.identity == expected else { throw CharacterLexiconError.changed }
            for chapter in lower..<upper {
                try Task.checkCancellation()
                guard ai.configuration == config else { throw CancellationError() }
                let text = try await value.source.load(chapter..<(chapter + 1))
                try Task.checkCancellation()
                guard text.count == 1, text.first?.index == chapter else { throw CharacterLexiconError.changed }
                guard ai.configuration == config else { throw CancellationError() }
                // 封面、版权页、作者简介和分卷标题页没有剧情，提前记检查点直接跳过：
                // 送进模型只会把作者／译者当成角色，还占掉一次请求预算。
                if text.allSatisfy({ $0.text.isEmpty }) || CharacterExtractionPlan.isNonContent(text) {
                    try store.completeEmptyChapter(book: key, identity: expected, chapter: chapter, scope: scope, signature: signature)
                } else {
                    let plan = try CharacterExtractionPlan(scope: scope, book: key, identity: expected, chapters: text)
                    guard plan.chunks.count <= limit else { throw CharacterLexiconError.chapterBudget(plan.chunks.count) }
                    guard requests + plan.chunks.count <= limit else { throw CharacterLexiconError.requestBudget }
                    try await CharacterAutomaticUpdater.update(plan: plan, store: store, ai: ai, beforeRequest: {
                        guard requests < limit else { throw CharacterLexiconError.requestBudget }; requests += 1
                    }) { index, count in progress("《\(book.title)》第\(chapter + 1)章 · \(index)/\(count)；本轮\(requests)次请求") }
                }
                completed += 1
            }
        }
        return (completed, requests)
    }
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
    let books: [LibraryBook]
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
                guard scope.permits(fact), let book = books.first(where: { $0.key == fact.book }) else { throw CharacterLexiconError.missing }
                let value = try await CharacterVolumeLoader.load(book, settings: settings)
                guard fact.chapter >= 0, fact.chapter < value.source.currentChapter else { throw CharacterLexiconError.changed }
                let values = try await value.source.load(fact.chapter..<(fact.chapter + 1))
                try Task.checkCancellation()
                guard let chapter = values.first else { throw CharacterLexiconError.changed }
                let exact = value.source.identity == fact.identity && fact.offset >= 0 && fact.offset <= chapter.text.utf16.count
                    && fact.quote.utf16.count <= chapter.text.utf16.count - fact.offset
                    && (chapter.text as NSString).substring(with: NSRange(location: fact.offset, length: fact.quote.utf16.count)) == fact.quote
                if let anchor = fact.attribution {
                    let anchorKey = anchor.book ?? fact.book
                    guard let anchorBook = books.first(where: { $0.key == anchorKey }), scope.permits(book: anchorKey, chapter: anchor.chapter) else { throw CharacterLexiconError.missing }
                    let anchorValue = anchorKey == fact.book ? value : try await CharacterVolumeLoader.load(anchorBook, settings: settings)
                    guard anchorValue.source.identity == (anchor.identity ?? fact.identity) else { throw CharacterLexiconError.changed }
                    let evidence = try await anchorValue.source.load(anchor.chapter..<(anchor.chapter + 1))
                    try Task.checkCancellation()
                    guard let text = evidence.first?.text as NSString?, anchor.offset >= 0, anchor.offset <= text.length,
                          anchor.quote.utf16.count <= text.length - anchor.offset,
                          text.substring(with: NSRange(location: anchor.offset, length: anchor.quote.utf16.count)) == anchor.quote else { throw CharacterLexiconError.changed }
                }
                if !exact {
                    guard fact.chapterTitle == chapter.title,
                          fact.chapter < value.boundary else { throw CharacterLexiconError.changed }
                    fallback = true
                }
                self.chapter = chapter
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

private enum CharacterPortraitImportError: LocalizedError {
    case invalid
    var errorDescription: String? { "无法读取图片或图片过大，请选择20 MiB以内的常用图片格式。" }
}
/// ImageIO缩略解码并重新编码，仅保留像素，不把EXIF/GPS等原始元数据写入角色图片。
enum CharacterPortraitCodec {
    nonisolated static func jpeg(_ data: Data, maximumPixels: Int) -> Data? {
        guard data.count <= 20 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 1_024 * 1_024 else { return nil }
        return output as Data
    }
}
@MainActor
private struct CharacterPortraitImage: View {
    @ObservedObject var store: CharacterLexiconStore
    let id: String
    let scope: CharacterScope
    let name: String
    let compact: Bool
    var fits = false
    @State private var image: UIImage?
    private var hash: String? { store.portrait(for: id, scope: scope)?.hash }
    var body: some View {
        Group {
            if let image {
                if fits { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                ZStack { Color(.secondarySystemBackground); Text(String(name.prefix(1))).font(compact ? .title3 : .largeTitle).foregroundStyle(NoveliaStyle.brandGreen) }
            }
        }
        .clipped().accessibilityLabel("角色形象")
        .task(id: hash) {
            image = nil
            guard let hash, let file = store.portraitFile(hash) else { return }
            let maximum = compact ? 160 : 1_024
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let data = try? Data(contentsOf: file), FileContentHash.sha256(data) == hash else { return nil }
                return CharacterPortraitCodec.jpeg(data, maximumPixels: maximum)
            }.value
            guard !Task.isCancelled, self.hash == hash else { return }
            image = data.flatMap { UIImage(data: $0) }
        }
    }
}
