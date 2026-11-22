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

// MARK: - 一键「回顾上一卷」

/// 复用全书故事梗概管线，一键回顾系列中上一卷的主要人物、主线进展与悬念；
/// 仅读取上一卷正文，绝不触及当前卷或后续卷内容。
@MainActor
struct PreviousVolumeRecapSheet: View {
    let previousBook: LibraryBook
    let currentBookTitle: String
    @ObservedObject var store: ReadingRecapStore
    @ObservedObject var ai: ReadingAIStore

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var libraryState: LibraryStateStore

    @State private var resolvedStorageKey: String?
    @State private var isPreparing = false
    @State private var localError: String?
    @State private var truncatedNotice = false
    @State private var copied = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var activeStorageKey: String? {
        if let resolvedStorageKey { return resolvedStorageKey }
        if let hash = libraryState.hashByBook[previousBook.key] ?? previousBook.cloudFileHash {
            return previousBook.positionPrefix + hash
        }
        return nil
    }

    private var hashedStoryKey: String? {
        activeStorageKey.map { FileContentHash.sha256(Data($0.utf8)) }
    }

    private var story: BookStorySummary? {
        activeStorageKey.flatMap { store.story(book: $0) }
    }

    private var storyProgress: String? {
        hashedStoryKey.flatMap { store.storyProgress[$0] }
    }

    private var storyError: String? {
        hashedStoryKey.flatMap { store.storyErrors[$0] } ?? localError
    }

    var body: some View {
        CompatNavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        LibraryCoverView(
                            book: previousBook,
                            width: 54,
                            height: 76,
                            fitMode: libraryState.coverFitMode(for: previousBook)
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(previousBook.title)
                                .font(.headline)
                                .foregroundStyle(NoveliaStyle.ink)
                            if !previousBook.author.isEmpty {
                                Text(previousBook.author)
                                    .font(.subheadline)
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                            Text("仅读取上一卷正文，绝不触及《\(currentBookTitle)》后续内容。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("上一卷")
                }

                Section {
                    if let story {
                        Text(story.text)
                            .font(.body)
                            .textSelection(.enabled)
                        HStack {
                            Text("已缓存 · 覆盖 \(story.coveredThrough) 章 · \(Self.dateFormatter.string(from: story.updatedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(copied ? "已复制" : "复制") {
                                UIPasteboard.general.string = story.text
                                copied = true
                            }
                            .font(.caption.weight(.medium))
                        }
                    } else if storyProgress == nil && !isPreparing {
                        Text("还没有上一卷的剧情梗概。点击下方按钮一键整理上一卷的主要人物、主线进展与遗留悬念，方便无缝衔接下一卷。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if truncatedNotice {
                        Text("上一卷篇幅较大，已自动按预算精选开篇与后半段核心章节进行概括。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if previousBook.isCloudOnly {
                        Text("上一卷目前仅在云端，请先在书库下载本机文件后再生成回顾。")
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.danger)
                    } else if isPreparing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取上一卷章节…")
                        }
                    } else if let storyProgress {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(storyProgress)
                        }
                        if let key = activeStorageKey {
                            Button("取消生成", role: .destructive) {
                                store.cancelStory(book: key)
                            }
                        }
                    } else {
                        Button {
                            Task { await generateRecap() }
                        } label: {
                            Label(story == nil ? "一键生成上一卷回顾" : "重新生成上一卷回顾", systemImage: "sparkles")
                        }
                        .disabled(!ai.isReadyForGeneration)
                        if !ai.isReadyForGeneration {
                            Text("请先在「我的 → 高级 → AI 阅读辅助」配置并启用 AI 服务。已有缓存回顾仍可直接阅读。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("将向 \((try? ai.configuration.endpoint().host) ?? "所配置接口") 发送上一卷正文进行分段概括与归并，可能产生模型费用。关闭此页不会中断后台生成。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let storyError {
                        Text(storyError)
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.danger)
                    }
                } header: {
                    Text("上一卷剧情回顾")
                }
            }
            .navigationTitle("回顾上一卷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func generateRecap() async {
        guard !isPreparing else { return }
        isPreparing = true
        localError = nil
        truncatedNotice = false
        defer { isPreparing = false }
        do {
            let volume = try await CharacterVolumeLoader.load(previousBook, settings: readerSettings)
            resolvedStorageKey = volume.source.bookKey
            let totalChapters = volume.source.currentChapter
            guard totalChapters > 0 else {
                localError = "未能从上一卷读取到有效章节。"
                return
            }
            let loaded = try await volume.source.load(0..<totalChapters)
            let fitted = StorySummaryPlan.fitChaptersToBudget(loaded)
            truncatedNotice = fitted.truncated
            guard !fitted.chapters.isEmpty else {
                localError = "上一卷正文为空，无法生成回顾。"
                return
            }
            store.startStory(
                book: volume.source.bookKey,
                chapters: fitted.chapters,
                previous: nil,
                identity: volume.source.identity,
                coveredThrough: totalChapters,
                ai: ai
            )
        } catch is CancellationError {
        } catch {
            localError = error.localizedDescription
        }
    }
}

// MARK: - 世界观词条

/// 轻小说「世界观词条」管理与防剧透 AI 提取界面（按系列或单书 workID 组织）。
@MainActor
struct WorldviewLexiconView: View {
    let workID: String
    let workTitle: String
    let books: [LibraryBook]
    var initialBookKey: String? = nil
    @ObservedObject var store: WorldviewLexiconStore
    @ObservedObject var ai: ReadingAIStore

    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var libraryState: LibraryStateStore

    @State private var query = ""
    @State private var selectedCategory: WorldviewCategory? = nil
    @State private var selectedBookKey = ""
    @State private var editingEntry: WorldviewEntry? = nil
    @State private var isCreatingEntry = false
    @State private var isPreparingExtraction = false
    @State private var localError: String? = nil

    private var localBooks: [LibraryBook] {
        books.filter { !$0.isCloudOnly }
    }

    private var allWorkEntries: [WorldviewEntry] {
        store.entries(for: workID)
    }

    private var filteredEntries: [WorldviewEntry] {
        store.entries(for: workID, query: query, category: selectedCategory)
    }

    private var progress: String? {
        store.extractionProgress[workID]
    }

    private var errorText: String? {
        store.extractionErrors[workID] ?? localError
    }

    private var summaryText: String? {
        store.lastExtractionSummary[workID]
    }

    var body: some View {
        List {
            Section {
                TextField("搜索词条、别名或释义", text: $query)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        categoryChip(title: "全部 (\(allWorkEntries.count))", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(WorldviewCategory.allCases) { category in
                            let count = allWorkEntries.filter { $0.category == category }.count
                            categoryChip(
                                title: count > 0 ? "\(category.title) (\(count))" : category.title,
                                isSelected: selectedCategory == category
                            ) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if localBooks.isEmpty {
                    Text("当前没有可扫描的本机书籍；你仍可点击右上角「+」手工记录世界观词条。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if localBooks.count > 1 {
                        Picker("扫描书籍", selection: $selectedBookKey) {
                            ForEach(localBooks) { book in
                                Text(book.title).tag(book.key)
                            }
                        }
                        .disabled(progress != nil || isPreparingExtraction)
                    }
                    if isPreparingExtraction {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取已读章节…")
                        }
                    } else if let progress {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(progress)
                        }
                        Button("取消提取", role: .destructive) {
                            store.cancelExtraction(workID: workID)
                        }
                    } else {
                        Button {
                            Task { await startAIExtraction() }
                        } label: {
                            Label("从已读正文提取世界观词条", systemImage: "sparkles")
                        }
                        .disabled(!ai.isReadyForGeneration)
                        if !ai.isReadyForGeneration {
                            Text("配置并启用 AI 阅读辅助后可自动提取；未启用 AI 时也支持完整手工维护。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("仅读取当前进度之前的已读章节（标记为「读过」的卷读取全卷），绝不剧透未读内容，也不会覆盖你手工编辑的词条。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let summaryText {
                        Text(summaryText)
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(NoveliaStyle.danger)
                    }
                }
            } header: {
                Text("AI 辅助提取")
            }

            Section {
                if filteredEntries.isEmpty {
                    Text(allWorkEntries.isEmpty
                         ? "还没有世界观词条。点击右上角「+」手工添加，或从已读正文一键提取设定、势力、地点与器物。"
                         : "没有匹配当前筛选条件的词条。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(filteredEntries) { entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: entry.category.systemImage)
                                        .font(.caption)
                                        .foregroundStyle(NoveliaStyle.brandGreen)
                                    Text(entry.term)
                                        .font(.headline)
                                        .foregroundStyle(NoveliaStyle.ink)
                                    Spacer()
                                    Text(entry.category.title)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(NoveliaStyle.brandGreen)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                                }
                                if !entry.aliases.isEmpty {
                                    Text("别名：\(entry.aliases.joined(separator: "、"))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(NoveliaStyle.ink.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 8) {
                                    if entry.isManual {
                                        Text("手工记录")
                                    } else if let bookTitle = entry.sourceBookTitle {
                                        let chapterPart = entry.sourceChapterIndex.map { " · 第 \($0 + 1) 章" } ?? ""
                                        Text("出处：\(bookTitle)\(chapterPart)")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.delete(id: entry.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("词条列表（\(filteredEntries.count)）")
            } footer: {
                Text("「世界观词条」仅用于个人阅读理解与设定备忘，与网站翻译术语表相互独立。")
            }
        }
        .navigationTitle(workTitle.isEmpty ? "世界观词条" : "\(workTitle) · 世界观词条")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarTrailing) {
                Button {
                    isCreatingEntry = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增世界观词条")
            }
        }
        .onAppear {
            if selectedBookKey.isEmpty {
                if let initialBookKey, localBooks.contains(where: { $0.key == initialBookKey }) {
                    selectedBookKey = initialBookKey
                } else {
                    selectedBookKey = localBooks.first?.key ?? ""
                }
            }
        }
        .sheet(isPresented: $isCreatingEntry) {
            WorldviewEntryEditorSheet(
                workID: workID,
                existing: nil,
                sourceBook: localBooks.first(where: { $0.key == selectedBookKey }) ?? localBooks.first
            ) { entry in
                store.upsert(entry)
            }
        }
        .sheet(item: $editingEntry) { entry in
            WorldviewEntryEditorSheet(
                workID: workID,
                existing: entry,
                sourceBook: nil
            ) { updated in
                store.upsert(updated)
            } onDelete: {
                store.delete(id: entry.id)
            }
        }
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : NoveliaStyle.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.card,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func startAIExtraction() async {
        guard !isPreparingExtraction else { return }
        guard let target = localBooks.first(where: { $0.key == selectedBookKey }) ?? localBooks.first else {
            localError = "未找到可扫描的本机书籍。"
            return
        }
        isPreparingExtraction = true
        localError = nil
        defer { isPreparingExtraction = false }
        do {
            let volume = try await CharacterVolumeLoader.load(target, settings: readerSettings)
            let isCompleted = libraryState.bookStatus(for: target) == .completed
            let upper = isCompleted ? volume.source.currentChapter : volume.boundary
            guard upper > 0 else {
                localError = "《\(target.title)》当前还没有已读完的章节。阅读至少一章（或将其标记为「读过」）后再提取，可确保不剧透未读内容。"
                return
            }
            let loaded = try await volume.source.load(0..<upper)
            let fitted = StorySummaryPlan.fitChaptersToBudget(loaded, maxBytes: 120 * 1_024)
            guard !fitted.chapters.isEmpty else {
                localError = "已读章节正文为空，无法提取。"
                return
            }
            store.startExtraction(
                workID: workID,
                chapters: fitted.chapters,
                sourceBookKey: target.key,
                sourceBookTitle: target.title,
                ai: ai
            )
        } catch is CancellationError {
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct WorldviewEntryEditorSheet: View {
    let workID: String
    let existing: WorldviewEntry?
    let sourceBook: LibraryBook?
    let onSave: (WorldviewEntry) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var aliasesText: String
    @State private var category: WorldviewCategory
    @State private var summary: String

    init(
        workID: String,
        existing: WorldviewEntry?,
        sourceBook: LibraryBook?,
        onSave: @escaping (WorldviewEntry) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.workID = workID
        self.existing = existing
        self.sourceBook = sourceBook
        self.onSave = onSave
        self.onDelete = onDelete
        _term = State(initialValue: existing?.term ?? "")
        _aliasesText = State(initialValue: existing?.aliases.joined(separator: "、") ?? "")
        _category = State(initialValue: existing?.category ?? .concept)
        _summary = State(initialValue: existing?.summary ?? "")
    }

    private var canSave: Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        CompatNavigationStack {
            Form {
                Section("词条信息") {
                    TextField("词条名称（如：固有结界、王立骑士团）", text: $term)
                    TextField("别名 / 简称（用顿号或逗号分隔，可选）", text: $aliasesText)
                    Picker("分类", selection: $category) {
                        ForEach(WorldviewCategory.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                }
                Section("释义") {
                    TextEditor(text: $summary)
                        .frame(minHeight: 110)
                }
                if existing != nil, let onDelete {
                    Section {
                        Button("删除词条", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "新增世界观词条" : "编辑世界观词条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let aliases = aliasesText
                            .split { $0 == "、" || $0 == "," || $0 == "，" || $0 == "/" }
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let now = Date()
                        let entry = WorldviewEntry(
                            id: existing?.id ?? UUID(),
                            workID: existing?.workID ?? workID,
                            term: term,
                            aliases: aliases,
                            category: category,
                            summary: summary,
                            sourceBookKey: existing?.sourceBookKey ?? sourceBook?.key,
                            sourceBookTitle: existing?.sourceBookTitle ?? sourceBook?.title,
                            sourceChapterIndex: existing?.sourceChapterIndex,
                            sourceChapterTitle: existing?.sourceChapterTitle,
                            isManual: true,
                            createdAt: existing?.createdAt ?? now,
                            updatedAt: now
                        )
                        onSave(entry)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
