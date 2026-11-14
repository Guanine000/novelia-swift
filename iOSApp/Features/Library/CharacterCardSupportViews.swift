// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 主列表与人物详情共用同一更新执行路径，防止界面改版改变范围、请求预算或检查点契约。
@MainActor
enum CharacterBookUpdater {
    /// 并发提取时共用的请求额度。请求体本身在后台线程，计数用锁保护以便从非隔离上下文调用。
    private final class RequestBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var usedValue = 0
        let limit: Int
        init(limit: Int) { self.limit = limit }
        var used: Int { lock.lock(); defer { lock.unlock() }; return usedValue }
        func reserve() throws {
            lock.lock(); defer { lock.unlock() }
            guard usedValue < limit else { throw CharacterLexiconError.requestBudget }
            usedValue += 1
        }
    }
    /// 每章的请求墙钟耗时；并发下由多个任务写入，用锁保护。
    private final class ChapterTimings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Int] = [:]
        func set(_ milliseconds: Int, for chapter: Int) {
            lock.lock(); values[chapter] = milliseconds; lock.unlock()
        }
        func value(_ chapter: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }; return values[chapter]
        }
    }
    private static func seconds(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        return String(format: "%.1f秒", Double(milliseconds) / 1_000)
    }
    /// 一个请求单位：要么是一段连续章节合并成一个计划，要么是一条没有正文的章节（直接记检查点）。
    private struct PreparedUnit {
        let chapters: [Int]
        let plan: CharacterExtractionPlan?
        var first: Int { chapters.first ?? 0 }
        var label: String { chapters.count > 1 ? "第 \(chapters[0] + 1)–\(chapters[chapters.count - 1] + 1) 章" : "第 \(first + 1) 章" }
    }
    /// 一次请求最多合并多少章：省掉每章一次首字等待与整段提示词，同时不让单次输出过大。
    private static let chaptersPerRequest = 3
    static func run(books: [LibraryBook], scope: CharacterScope, selection: [String], settings: ReaderSettings,
                    store: CharacterLexiconStore, ai: ReadingAIStore, limit: Int, concurrency: Int = 1,
                    progress: (String) -> Void) async throws -> (completed: Int, requests: Int, modelMilliseconds: Int, localMilliseconds: Int) {
        let config = ai.configuration
        guard store.order(work: scope.work) == scope.volumes else { throw CharacterLexiconError.scope }
        guard ai.isReadyForGeneration else { throw ai.configuration.isEnabled ? ReadingAIError.missingKey : ReadingAIError.disabled }
        let budget = RequestBudget(limit: limit)
        // 并发只发生在请求阶段：落盘严格按章序，检查点才不会被后面的章节跳过前面的失败章。
        let parallel = max(1, min(6, concurrency))
        let window = parallel * Self.chaptersPerRequest
        var completed = 0
        // 分段计时：把"读章/分块"算作本地，"等待模型生成"算作模型，落盘单独计。
        var modelMilliseconds = 0, localMilliseconds = 0
        func now() -> Date { Date() }
        func milliseconds(since start: Date) -> Int { Int(now().timeIntervalSince(start) * 1_000) }
        for key in selection {
            try Task.checkCancellation()
            guard ai.configuration == config else { throw CancellationError() }
            guard let book = books.first(where: { $0.key == key }), let expected = scope.identities[key], let upper = scope.readBoundaries?[key], upper > 0 else { continue }
            let signature = try CharacterAutomaticUpdater.signature(identity: expected, scope: scope, configuration: config)
            let lower = store.scannedThrough(work: scope.work, book: key, signature: signature)
            guard lower < upper else { continue }
            let value = try await CharacterVolumeLoader.load(book, settings: settings)
            guard value.source.identity == expected else { throw CharacterLexiconError.changed }

            var chapter = lower
            while chapter < upper {
                try Task.checkCancellation()
                guard ai.configuration == config else { throw CancellationError() }
                var batch = [PreparedUnit]()
                let timings = ChapterTimings()
                // 整批一次性取正文：EPUB 的读取闭包每次调用都会重算整本哈希并重新解包，
                // 按章逐次调用会让本地解包串行排到网络请求前面。
                let end = min(chapter + window, upper)
                let loadStart = now()
                let texts = try await value.source.load(chapter..<end)
                localMilliseconds += milliseconds(since: loadStart)
                try Task.checkCancellation()
                guard texts.count == end - chapter, texts.enumerated().allSatisfy({ $0.element.index == chapter + $0.offset }) else {
                    throw CharacterLexiconError.changed
                }
                let planStart = now()
                var pack = [RecapChapter]()
                var packBytes = 0
                func flushPack() throws {
                    guard !pack.isEmpty else { return }
                    let plan = try CharacterExtractionPlan(scope: scope, book: key, identity: expected, chapters: pack,
                                                           maxChaptersPerChunk: Self.chaptersPerRequest)
                    guard plan.chunks.count <= limit else { throw CharacterLexiconError.chapterBudget(plan.chunks.count) }
                    batch.append(PreparedUnit(chapters: pack.map(\.index), plan: plan))
                    pack.removeAll(); packBytes = 0
                }
                for text in texts {
                    // 封面、版权页、作者简介和分卷标题页没有剧情，直接记检查点跳过：
                    // 送进模型只会把作者／译者当成角色，还占掉一次请求预算。
                    let empty = text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || CharacterExtractionPlan.isNonContent([text])
                    if empty {
                        try flushPack()
                        batch.append(PreparedUnit(chapters: [text.index], plan: nil))
                        continue
                    }
                    let bytes = text.text.utf8.count
                    if !pack.isEmpty, pack.count >= Self.chaptersPerRequest || packBytes + bytes + 1 > 8_000 {
                        try flushPack()
                    }
                    pack.append(text); packBytes += bytes + (pack.count > 1 ? 1 : 0)
                }
                try flushPack()
                localMilliseconds += milliseconds(since: planStart)
                let cursor = end
                guard budget.used + batch.compactMap({ $0.plan?.chunks.count }).reduce(0, +) <= limit else { throw CharacterLexiconError.requestBudget }

                if let last = batch.last, batch.contains(where: { $0.plan != nil }) {
                    progress("《\(book.title)》\(batch.map(\.label).joined(separator: "、"))处理中；本轮\(budget.used)次请求")
                }
                var results = CharacterOrderedResults<CharacterAutomaticUpdater.Extraction?>(order: batch.map(\.first))
                for item in batch where item.plan == nil { results.receive(.success(nil), at: item.first) }
                func commit(_ number: Int, _ extraction: CharacterAutomaticUpdater.Extraction?) throws {
                    try Task.checkCancellation()
                    guard ai.configuration == config,
                          let item = batch.first(where: { $0.first == number }) else { throw CancellationError() }
                    let applyStart = now()
                    if let plan = item.plan, let extraction {
                        try CharacterAutomaticUpdater.apply(extraction, plan: plan, store: store)
                    } else if let only = item.chapters.first {
                        try store.completeEmptyChapter(book: key, identity: expected, chapter: only, scope: scope, signature: signature)
                    }
                    let applyMilliseconds = milliseconds(since: applyStart)
                    localMilliseconds += applyMilliseconds
                    completed += item.chapters.count
                    progress("《\(book.title)》\(item.label)已保存 · 请求 \(Self.seconds(timings.value(item.first))) · 落盘 \(applyMilliseconds)ms；本轮\(budget.used)次请求")
                }
                try results.drain(commit)
                let modelStart = now()
                try await withThrowingTaskGroup(of: (Int, Result<CharacterAutomaticUpdater.Extraction, Error>).self) { group in
                    for item in batch {
                        guard let plan = item.plan else { continue }
                        group.addTask {
                            let chapterStart = Date()
                            let key = item.first
                            do {
                                let extraction = try await CharacterAutomaticUpdater.extract(plan: plan, store: store, ai: ai,
                                    beforeRequest: { try budget.reserve() }) { _, _ in }
                                timings.set(Int(Date().timeIntervalSince(chapterStart) * 1_000), for: key)
                                return (key, .success(extraction))
                            } catch {
                                timings.set(Int(Date().timeIntervalSince(chapterStart) * 1_000), for: key)
                                return (key, .failure(error))
                            }
                        }
                    }
                    for try await (number, extraction) in group {
                        results.receive(extraction.map { Optional($0) }, at: number)
                        do { try results.drain(commit) }
                        catch { group.cancelAll(); throw error }
                    }
                }
                modelMilliseconds += milliseconds(since: modelStart)

                chapter = cursor
            }
        }
        return (completed, budget.used, modelMilliseconds, localMilliseconds)
    }
}

@MainActor
struct CharacterFactEditor: View {
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
struct CharacterEvidenceView: View {
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

enum CharacterPortraitImportError: LocalizedError {
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
struct CharacterPortraitImage: View {
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

/// 并发提取的收口：同名多卡逐组确认合并。默认保留事实最多的一张，
/// 合并后事实与图片都进目标卡，来源卡删除；不按别名或相似名猜测。
@MainActor
struct CharacterDuplicateReviewView: View {
    let scope: CharacterScope
    @ObservedObject var store: CharacterLexiconStore
    @State private var error: String?
    @State private var message: String?
    private var groups: [CharacterDuplicateGroup] { store.duplicates(scope: scope) }
    var body: some View {
        List {
            if groups.isEmpty {
                Section { Text("没有需要合并的同名人物。").foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.members) { member in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(member.name)
                                if member.id == group.members.first?.id {
                                    Text("合并到此").font(.caption2).foregroundStyle(NoveliaStyle.brandGreen)
                                }
                                Spacer()
                                Text("\(member.facts.count)条").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("第\(member.facts.map(\.chapter).min().map { $0 + 1 } ?? 1)起 · 共\(member.facts.count)条事实")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("合并为一张") { merge(group) }
                } header: { Text(group.name + " · \(group.members.count)张") }
            }
            if let message { Section { Text(message).font(.footnote) } }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(NoveliaStyle.danger) } }
        }
        .navigationTitle("校准重复人物")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("全部合并") { for group in groups { merge(group) } }.disabled(groups.isEmpty)
        }
    }
    private func merge(_ group: CharacterDuplicateGroup) {
        guard let target = group.members.first else { return }
        error = nil
        var merged = 0
        for member in group.members where member.id != target.id {
            do { try store.merge(member.id, into: target.id, scope: scope); merged += 1 }
            catch { self.error = error.localizedDescription; return }
        }
        message = "「\(group.name)」已合并\(merged)张卡到事实最多的一张。"
    }
}

/// 对话展示来自真实任务事件和已保存结果，不增加模型调用，也不展示推测的思考过程。
/// 直接观察共享 Store，面板打开后仍随任务完成、失败和暂停实时更新。
@MainActor
struct CharacterAILogView: View {
    let workID: String
    @ObservedObject var store: CharacterLexiconStore
    @ObservedObject var ai: ReadingAIStore
    let canContinue: Bool
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var followsLatest = true
    private var run: CharacterLexiconStore.RunState? { store.runs[workID] }
    private var running: Bool { store.runningTasks[workID] != nil }
    private var replies: [ReadingAIStore.RequestProgress] {
        let owner = run?.replySession?.uuidString
        return (ai.completedReplies + Array(ai.requestProgress.values)).filter { $0.conversationID == owner && owner != nil }
            .sorted { $0.started < $1.started }
    }
    private var revision: String { "\(run?.events.count ?? 0)|\(run?.progress ?? "")|\(run?.message ?? "")|\(replies.reduce(0) { $0 + $1.characters })" }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if let request = run?.userRequest { bubble(request, user: true) }
                            ForEach(Array((run?.events ?? []).enumerated()), id: \.offset) { index, event in
                                if index == 0 && !event.hasPrefix("《") {
                                    bubble(event)
                                } else {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: event.contains("已保存") ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                                            .foregroundStyle(NoveliaStyle.brandGreen)
                                        Text(event).font(.footnote).foregroundStyle(NoveliaStyle.muted)
                                    }.padding(.leading, 8).accessibilityElement(children: .combine)
                                }
                            }
                            ForEach(replies) { reply in
                                VStack(alignment: .leading, spacing: 6) {
                                    bubble(CharacterReplyPresentation.text(reply.preview).isEmpty ? "正在接收人物资料…" : CharacterReplyPresentation.text(reply.preview))
                                    Text(reply.status).font(.caption).foregroundStyle(NoveliaStyle.muted).padding(.leading, 14)
                                    DisclosureGroup("原始回复") {
                                        Text(reply.preview).font(.system(.caption, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                                    }.font(.caption).padding(.leading, 14)
                                }
                            }
                            if running {
                                HStack(alignment: .top, spacing: 10) {
                                    ProgressView()
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(run?.progress ?? "正在准备…").font(.footnote)
                                        Text("完成的章节会自动保存，可以先返回阅读。")
                                            .font(.caption).foregroundStyle(NoveliaStyle.muted)
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(NoveliaStyle.card).clipShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
                            }
                            if let message = run?.message { bubble(message) }
                            DisclosureGroup("运行详情") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("以下为当前 AI 请求的原始回复片段，人物资料保存前会核验出处。")
                                        .font(.caption).foregroundStyle(NoveliaStyle.muted)
                                    ForEach(ai.requestProgress.values.sorted { $0.id.uuidString < $1.id.uuidString }) { request in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("请求 " + String(request.id.uuidString.prefix(6)) + " · 已接收 \(request.characters) 字").font(.caption)
                                            Text(request.preview.isEmpty ? "等待模型回复…" : request.preview)
                                                .font(.system(.caption, design: .monospaced))
                                        }
                                    }
                                    if ai.requestProgress.isEmpty { Text("当前没有运行中的请求").font(.caption) }
                                }.padding(.top, 8)
                            }.font(.footnote).foregroundStyle(NoveliaStyle.muted)
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(16)
                    }
                    .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                    .onValueChange(of: revision) { _, _ in
                        if followsLatest { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
                    }
                }
                Divider()
                VStack(spacing: 10) {
                    Toggle("跟随最新消息", isOn: $followsLatest).font(.caption)
                    HStack(spacing: 12) {
                        Button("查看人物卡") { dismiss() }.buttonStyle(.bordered)
                        Spacer()
                        if running {
                            Button("暂停整理") { store.pause(work: workID) }.buttonStyle(.borderedProminent)
                        } else {
                            Button("继续更新") { onContinue() }.buttonStyle(.borderedProminent).disabled(!canContinue)
                        }
                    }
                }.padding(16)
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle("阅读助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .compatTopBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }
    private func bubble(_ text: String, user: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                Text(user ? "你" : "阅读助手").font(.caption).foregroundStyle(NoveliaStyle.muted)
                Text(text).font(.body).foregroundStyle(NoveliaStyle.ink).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
                .background(user ? NoveliaStyle.brandGreen.opacity(0.12) : NoveliaStyle.card)
                .clipShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
            if !user { Spacer(minLength: 16) }
        }.accessibilityElement(children: .combine)
    }
}

/// 手工新增事实：用户自己写的内容不需要原文引文，保存后标为手工条目。
@MainActor
struct CharacterFactCreator: View {
    let save: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var category = "身份"
    @State private var error: String?
    private let categories = ["身份", "外貌", "性格", "能力", "目标", "关系", "经历"]
    var body: some View {
        NavigationView {
            Form {
                Section("事实描述") {
                    TextEditor(text: $text).frame(minHeight: 100)
                }
                Section("类别") {
                    Picker("类别", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                }
                Section {
                    Text("手工条目没有原文引文，出处会留空；AI 再次补充细节时不会覆盖它。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(NoveliaStyle.danger) }
            }
            .navigationTitle("新增人物事实")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try save(text, category); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
