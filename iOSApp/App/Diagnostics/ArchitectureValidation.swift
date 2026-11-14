// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import Foundation
import UIKit
import ReadiumZIPFoundation

extension AppServices {
    /// 只允许独立 Debug App 使用的替代组装，创建合成后台和内存会话。
    /// 重置仅影响该应用容器；保留独立 bundle 校验，不能接入生产凭据或用户书库。
    static func architectureValidation() -> AppServices {
        precondition(Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation",
                     "Architecture validation requires its dedicated application bundle.")
        if ProcessInfo.processInfo.arguments.contains("-resetArchitectureValidation") {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            for name in ["Library", "WebNovelDownloads", "WenkuEPUB", "ReadingStatistics", "Bookmarks", "Annotations", "CharacterPortraits"] {
                try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-seedPerformanceLibrary") {
            seedPerformanceLibrary()
        }
        if ProcessInfo.processInfo.arguments.contains("-architectureLegacyWebEPUB") {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let index = support.appendingPathComponent("WebNovelDownloads/library.json")
            if let data = try? Data(contentsOf: index), var records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for i in records.indices { records[i].removeValue(forKey: "downloadMode"); records[i].removeValue(forKey: "translationSource") }
                if let encoded = try? JSONSerialization.data(withJSONObject: records) { try? encoded.write(to: index, options: .atomic) }
            }
        }
        URLProtocol.registerClass(ArchitectureNetworkTrap.self)
        let readium = ProcessInfo.processInfo.arguments.contains("-architectureReadium")
        UserDefaults.standard.set(readium, forKey: SettingsKey.readerEPUBReadium)
        if ProcessInfo.processInfo.arguments.contains("-architectureTXT") {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("WenkuEPUB", isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sentence = ProcessInfo.processInfo.arguments.contains("-architectureCharacterPortrait")
                ? "林舟是港口调查员，沉着寡言，重视承诺。\n林舟在寻找失踪的妹妹林澈，始终没有放弃。\n林舟与白岚是同行伙伴，两人决定共同调查。\n林舟在旧码头发现妹妹失踪的线索，并收起了地图。\n林舟猜想面具人来自北方，但尚未找到确切证据。\n林舟可能知道旧仓库的秘密，但他没有说明。\n\n" : "本地TXT验证正文，通过原有分章和Readium管线阅读。\n\n"
            let text = "第一章 起点\n" + String(repeating: sentence, count: 80)
                + "第二章 续听\n" + String(repeating: ProcessInfo.processInfo.arguments.contains("-architectureCharacterPortrait") ? "林舟决定与白岚共同调查，并约定次日在旧码头会合。\n\n" : "第二章验证正文，用于跨章续听和重启恢复。\n\n", count: 80)
                + "第三章 终点\n" + String(repeating: "第三章验证正文，用于完整分章识别。\n\n", count: 80)
            try! Data(text.utf8).write(to: directory.appendingPathComponent("architecture.txt"))
            let record = LocalWenkuEPUB(id: UUID(), title: "架构验证TXT", filename: "architecture.txt", addedAt: Date(),
                                       metadataLoaded: true, fileFormat: .txt)
            try! JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("library.json"))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let credentials = ArchitectureLocalCredentials()
        let local = LocalAppServices(
            defaults: .standard,
            bookmarks: ReaderBookmarkStore(directory: support.appendingPathComponent("Bookmarks")),
            annotations: ReaderAnnotationStore(directory: support.appendingPathComponent("Annotations")),
            statistics: ReadingStatisticsStore(defaults: .standard, deviceIDs: credentials,
                                                directory: support.appendingPathComponent("ReadingStatistics")),
            blockedTags: BlockedTagsStore(defaults: .standard),
            backgrounds: ReaderBackgroundStore(defaults: .standard, directory: support.appendingPathComponent("ReaderBackgrounds")),
            cloudBooks: CloudBookStore(directory: support.appendingPathComponent("WebDAVCloudBooks")),
            passwordStore: WebDAVPasswordStore(load: { credentials.password }, save: { credentials.password = $0 }))
        if ProcessInfo.processInfo.arguments.contains("-architectureRecapMissingKey") {
            let url = support.appendingPathComponent("WenkuEPUB/architecture.txt")
            let hash = try! FileContentHash.sha256(url)
            local.positions.recordTXT(hash: hash, position: .init(chapter: 2))
            local.readerSettings.recaps.recordReading(book: "txt:" + hash, now: Date().addingTimeInterval(-8 * 86_400))
            var value = ReadingAIConfiguration(); value.isEnabled = true; value.baseURL = "https://unused.example/v1"; value.model = "fixture"
            UserDefaults.standard.set(try! JSONEncoder().encode(value), forKey: "reader.ai.configuration.v1")
        }
        if ProcessInfo.processInfo.arguments.contains("-architectureCharacterPortrait") {
            let directory = support.appendingPathComponent("WenkuEPUB", isDirectory: true)
            let records = try! JSONDecoder().decode([LocalWenkuEPUB].self, from: Data(contentsOf: directory.appendingPathComponent("library.json")))
            let record = records.first { $0.filename == "architecture.txt" }!
            let url = directory.appendingPathComponent(record.filename)
            let book = LibraryBook(origin: .wenku(record), fileURL: url, coverURL: nil)
            local.positions.recordTXT(hash: try! FileContentHash.sha256(url), position: .init(chapter: 2))
            // 单书变体验证“更多 → AI 人物词条”直达：不建系列，作品键直接用书键。
            let standalone = ProcessInfo.processInfo.arguments.contains("-architectureCharacterStandalone")
            let series = standalone ? book.key : local.library.createSeries(named: "雾港来信")
            if !standalone { local.library.assign(book, to: series) }
            local.library.markOpened(book)
            try! local.readerSettings.characters.confirmOrder(work: series, volumes: [book.key])
            if ProcessInfo.processInfo.arguments.contains("-architectureCharacterConversation") {
                // 合成对话仅供独立 Debug App 检查布局，不读取凭据或请求真实模型。
                local.readerSettings.characters.runs[series] = .init(
                    message: "本轮完成2章，人物卡已保存。", events: [
                        "我会先检查本地书籍和阅读位置，再分章整理人物资料。",
                        "《架构验证TXT》第 1–2 章并行处理中",
                        "《架构验证TXT》第 1 章已保存",
                        "《架构验证TXT》第 2 章已保存"
                    ], userRequest: "请整理这本书已读范围内的人物资料。", replySession: UUID())
            }
            Task {
                let volume = try! await CharacterVolumeLoader.load(book, settings: local.readerSettings)
                let scope = CharacterScope(work: series, volumes: [book.key], currentBook: book.key, currentChapter: 2,
                    identities: [book.key: volume.source.identity], readBoundaries: [book.key: 2])
                let chapters = try! await volume.source.load(0..<2)
                func fact(_ text: String, quote: String, category: String, chapter: Int = 0, related: String? = nil, pending: Bool = false) -> CharacterFact {
                    let offset = (chapters[chapter].text as NSString).range(of: quote).location
                    return CharacterFact(book: book.key, identity: volume.source.identity, chapter: chapter, offset: offset,
                        name: "林舟", text: text, quote: quote, category: category, needsReview: pending, relatedName: related)
                }
                let identityQuote = "林舟是港口调查员，沉着寡言，重视承诺。"
                let goalQuote = "林舟在寻找失踪的妹妹林澈，始终没有放弃。"
                let facts = [
                    fact("港口调查员", quote: identityQuote, category: "身份"),
                    fact("沉着、重视承诺", quote: identityQuote, category: "性格"),
                    fact("寻找失踪的妹妹", quote: goalQuote, category: "目标"),
                    fact("同行伙伴", quote: "林舟与白岚是同行伙伴，两人决定共同调查。", category: "关系", related: "白岚"),
                    fact("妹妹", quote: goalQuote, category: "关系", related: "林澈"),
                    fact("在旧码头发现失踪线索", quote: "林舟在旧码头发现妹妹失踪的线索，并收起了地图。", category: "经历"),
                    fact("决定与白岚共同调查", quote: "林舟决定与白岚共同调查，并约定次日在旧码头会合。", category: "经历", chapter: 1),
                    fact("面具人可能来自北方", quote: "林舟猜想面具人来自北方，但尚未找到确切证据。", category: "身份", pending: true),
                    fact("可能知晓旧仓库的秘密", quote: "林舟可能知道旧仓库的秘密，但他没有说明。", category: "能力", pending: true)
                ]
                let id = "portrait-fixture-person"
                let plan = try! CharacterExtractionPlan(scope: scope, book: book.key, identity: volume.source.identity, chapters: chapters)
                let signature = try! CharacterAutomaticUpdater.signature(identity: volume.source.identity, scope: scope, configuration: ReadingAIConfiguration())
                try! local.readerSettings.characters.applyAutomatic([.init(id: id, facts: facts)], plan: plan, signature: signature)
                let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).pngData { context in
                    UIColor(red: 0.33, green: 0.59, blue: 0.46, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                    UIColor.white.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 160, y: 150, width: 280, height: 280))
                    context.cgContext.fill(CGRect(x: 110, y: 460, width: 380, height: 260))
                }
                let jpeg = CharacterPortraitCodec.jpeg(image, maximumPixels: 1_024)!
                try! local.readerSettings.characters.setPortrait(jpeg, entity: id, scope: scope)
            }
        }
        local.readerSettings.pagedTextReading = readium
        let configuration = APIConfiguration(
            novelAPI: URL(string: "https://novels.example.invalid/api/")!,
            forumAPI: URL(string: "https://forum.example.invalid/api/v1/")!,
            bookCommentsOrigin: URL(string: "https://forum.example.invalid/")!,
            novelOrigin: URL(string: "https://novels.example.invalid")!,
            forumOrigin: URL(string: "https://forum.example.invalid")!,
            authentication: try! AuthenticationConfiguration(origin: URL(string: "https://auth.example.invalid")!))
        let failure = ProcessInfo.processInfo.arguments.contains("-architectureFailFirstSearch") ? "searchNovels" : nil
        let ambiguous = ProcessInfo.processInfo.arguments.contains("-architectureWebEPUBAmbiguous")
        let large = ProcessInfo.processInfo.arguments.contains("-architectureLargeWebEPUB")
        let webUpdate = ProcessInfo.processInfo.arguments.contains("-architectureWebEPUBUpdate")
        let initialFile: @Sendable () async throws -> URL = {
            if webUpdate { return try await ArchitectureWebEPUBFixture.file(updated: false, ambiguous: ambiguous, countOverride: large ? 130 : nil) }
            return try await EPUBSampleBook.sampleURL()
        }
        let newerFile: (@Sendable () async throws -> URL)?
        if webUpdate { newerFile = { try await ArchitectureWebEPUBFixture.file(updated: true, ambiguous: ambiguous, countOverride: large ? 131 : nil) } }
        else { newerFile = nil }
        let backend = ArchitectureFixtureBackend(initialFailure: failure, sampleFile: initialFile, updatedSampleFile: newerFile, ambiguousChapters: ambiguous, directorySize: large ? 131 : nil, onCall: { ArchitectureNetworkTrap.serviceCalled($0) })
        let refreshQueue = SerialAsyncGate()
        let account = AccountAuthStore(configuration: configuration,
            tokenStore: FixtureTokenStore(username: ArchitectureFixtureBackend.username), refreshQueue: refreshQueue)
        let forum = ForumAuthStore(configuration: configuration,
            tokenStore: FixtureTokenStore(username: ArchitectureFixtureBackend.username), refreshQueue: refreshQueue)
        let conversationAI: ReadingAIStore?
        if ProcessInfo.processInfo.arguments.contains("-architectureCharacterConversation") {
            let ai = ReadingAIStore(defaults: local.readerSettings.defaults, keys: MemoryReadingAIKeys(), client: ArchitectureCharacterReplyAI())
            var value = ReadingAIConfiguration(); value.baseURL = "https://unused.example/v1"; value.model = "fixture"
            try! ai.save(value, newKey: "synthetic-fixture-key")
            if let session = local.readerSettings.characters.runs.values.first?.replySession {
                Task { _ = try? await ReadingAIStore.$conversationID.withValue(session.uuidString) { try await ai.testConnection() } }
            }
            conversationAI = ai
        } else { conversationAI = nil }
        return AppServices(configuration: configuration, api: backend.services(), account: account,
            forumAccount: forum, local: local, performsUpdateChecks: false,
            speechService: ProcessInfo.processInfo.arguments.contains("-architectureSpeechAudio") ? ArchitectureSpeechAudio() : nil, readingAI: conversationAI)
    }
    /// 只为独立 Debug App 生成固定合成样本，基准脚本在计时前单独执行此步骤。
    private static func seedPerformanceLibrary() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-performanceLibraryCount"), arguments.indices.contains(index + 1),
              let count = Int(arguments[index + 1]), [0, 300, 3000].contains(count) else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WenkuEPUB", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var records: [LocalWenkuEPUB] = []
            for item in 0..<count {
                let filename = "benchmark-\(item).txt"
                let text = "第一章 起点\n性能基准正文 \(item)\n第二章 后续\n合成文本。"
                try Data(text.utf8).write(to: directory.appendingPathComponent(filename))
                records.append(LocalWenkuEPUB(id: UUID(), title: String(format: "基准书籍 %04d", item),
                    filename: filename, addedAt: Date(timeIntervalSince1970: Double(item)), metadataLoaded: true, fileFormat: .txt))
            }
            if arguments.contains("-performanceLargeTXT") {
                let sentence = "性能基准正文，用于测量本地长文本的首次打开。\n"
                let paragraph = String(repeating: sentence, count: max(1, (9 * 1024 * 1024 / 300 - 128) / sentence.utf8.count))
                var text = ""
                for chapter in 1...300 { text += "第\(chapter)章 基准章节\n" + paragraph }
                try Data(text.utf8).write(to: directory.appendingPathComponent("benchmark-large.txt"))
                records.append(LocalWenkuEPUB(id: UUID(), title: "基准长 TXT", filename: "benchmark-large.txt",
                    addedAt: Date(), metadataLoaded: true, fileFormat: .txt))
            }
            try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        } catch { preconditionFailure("Unable to seed isolated performance fixtures") }
    }

}

/// 验证组装的设备身份和同步密码只存内存，不读取或写入 Keychain。
private final class ArchitectureLocalCredentials: ReadingDeviceIDStoring {
    private var deviceID: String?
    var password: String?
    func load() -> String? { deviceID }
    func save(_ id: String) -> Bool { deviceID = id; return true }
}
#endif

#if DEBUG
import SwiftUI

/// 独立验证进程的 URLSession 外网拦截与计数；允许 Readium 本地服务。
/// 不覆盖任意 WebKit 网页请求，不能将计数为零解释为所有网络均已审计。
final class ArchitectureNetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    private static var chapterAttempts = 0
    private static var localDocumentAttempts = 0
    private static var batchAttempts = 0
    private static var downloadAttempts = 0
    static var downloadCount: Int { lock.lock(); defer { lock.unlock() }; return downloadAttempts }
    static var batchCount: Int { lock.lock(); defer { lock.unlock() }; return batchAttempts }
    static var localDocumentCount: Int { lock.lock(); defer { lock.unlock() }; return localDocumentAttempts }
    static var chapterCount: Int { lock.lock(); defer { lock.unlock() }; return chapterAttempts }
    static func serviceCalled(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if name == "chapter" { chapterAttempts += 1 }
        if name == "localEPUBDocument" { localDocumentAttempts += 1 }
        if name == "localEPUBBatch" { batchAttempts += 1 }
        if name == "downloadWebNovelEPUB" { downloadAttempts += 1 }
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, ["http", "https"].contains(url.scheme ?? "") else { return false }
        return !["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

/// 独立验证App专用的静音WAV，运行真实云端播放器而不发送网络正文。
private struct ArchitectureSpeechAudio: CloudSpeechSynthesizing {
    func audio(text: String, voice: String, rate: Double) async throws -> Data {
        let byteCount: UInt32 = 8_000 * 2 * 60
        var data = Data("RIFF".utf8)
        func word(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func short(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        word(36 + byteCount); data.append(Data("WAVEfmt ".utf8)); word(16)
        short(1); short(1); word(8_000); word(16_000); short(2); short(16)
        data.append(Data("data".utf8)); word(byteCount); data.append(Data(count: Int(byteCount)))
        return data
    }
}

/// 显示验证进程的外部请求计数，供自动化读取；不参与业务交互且不进入 Release。
struct ArchitectureValidationIndicator: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("验证环境 · 外部请求 \(ArchitectureNetworkTrap.count) · 正文请求 \(ArchitectureNetworkTrap.chapterCount) · 本机正文 \(ArchitectureNetworkTrap.localDocumentCount) · 批次 \(ArchitectureNetworkTrap.batchCount) · EPUB请求 \(ArchitectureNetworkTrap.downloadCount) · Readium起播 \(ReadiumSpeechEngine.validationStartCount)")
                .font(.caption2).padding(4).background(.regularMaterial).allowsHitTesting(false)
                .accessibilityIdentifier("architecture-validation-status")
        }
    }
}

/// 独立验证App的旧版/新版网络EPUB：网站有两章，初始文件只有一章，更新新增第二章。
private enum ArchitectureWebEPUBFixture {
    static func file(updated: Bool, ambiguous: Bool = false, countOverride: Int? = nil) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("architecture-web-\(updated ? "new" : "old").epub")
        try? FileManager.default.removeItem(at: url)
        let archive = try await Archive(url: url, accessMode: .create)
        func add(_ path: String, _ text: String, compressed: Bool = true) async throws {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await archive.addEntry(with: path, fileURL: temporary, compressionMethod: compressed ? .deflate : .none)
        }
        try await add("mimetype", "application/epub+zip", compressed: false)
        try await add("META-INF/container.xml", "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
        let count = countOverride ?? (ambiguous ? (updated ? 3 : 2) : (updated ? 2 : 1))
        func title(_ index: Int) -> String { countOverride != nil ? "验证章节 \(index)" : ambiguous ? "幕间" : (index == 1 ? "第一章" : "第二章") }
        let items = (1...count).map { "<item id=\"c\($0)\" href=\"Text/episode\($0).xhtml\" media-type=\"application/xhtml+xml\"/>" }.joined()
        let spine = (1...count).map { "<itemref idref=\"c\($0)\"/>" }.joined()
        try await add("book.opf", "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"book\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book\">fixture-one</dc:identifier><dc:title>架构验证小说</dc:title><dc:language>zh</dc:language></metadata><manifest>\(items)<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine>\(spine)</spine></package>")
        let links = (1...count).map { "<li><a href=\"Text/episode\($0).xhtml\">\(title($0))</a></li>" }.joined()
        try await add("nav.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol>\(links)</ol></nav></body></html>")
        let text = String(repeating: "这是替代服务提供的阅读正文，章节获取不经过真实服务器。", count: 50)
        for index in 1...count {
            let title = title(index)
            try await add("Text/episode\(index).xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title)</title></head><body><h1>\(title)</h1><p>\(text)</p></body></html>")
        }
        return url
    }
}
/// 合成流式回复，只供独立验证 App 检查消息展示，不连接外部接口。
private struct ArchitectureCharacterReplyAI: ReadingAICompleting {
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest) async throws -> ReadingAIResponse {
        .init(text: #"{"candidates":[{"name":"林舟","facts":[{"text":"港口调查员，沉着寡言，重视承诺。"},{"text":"正在寻找失踪的妹妹林澈。"}]}]}"#, inputTokens: nil, outputTokens: nil)
    }
    func complete(configuration: ReadingAIConfiguration, apiKey: String, request: ReadingAIRequest,
                  onProgress: @escaping @Sendable (Int, String) -> Void) async throws -> ReadingAIResponse {
        let result = try await complete(configuration: configuration, apiKey: apiKey, request: request)
        for count in stride(from: 20, to: result.text.count, by: 20) {
            try Task.checkCancellation()
            let partial = String(result.text.prefix(count)); onProgress(partial.count, partial)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        onProgress(result.text.count, result.text)
        return result
    }
}
/// 只在独立验证 App 中改变内容区宽度和尺寸类别，不模拟或宣称系统真实分屏。
/// RootView 始终是同一个实例，用于核对分栏收起/展开时搜索、选择和导航状态的连续性。
struct ArchitectureBrowseViewport: ViewModifier {
    @State private var narrow = false
    private var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation"
            && ProcessInfo.processInfo.arguments.contains("-architectureValidation")
            && ProcessInfo.processInfo.arguments.contains("-architectureBrowseResize")
    }
    func body(content: Content) -> some View {
        if isEnabled {
            GeometryReader { geometry in
                content
                    .frame(width: narrow ? min(480, geometry.size.width) : geometry.size.width, height: geometry.size.height)
                    .environment(\.horizontalSizeClass, narrow ? .compact : .regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .overlay(alignment: .bottomTrailing) {
                        Button(narrow ? "验证：恢复宽窗口" : "验证：切换窄窗口") { narrow.toggle() }
                            .padding(12)
                            .background(.regularMaterial)
                            .accessibilityIdentifier("architecture-browse-resize")
                    }
            }
        } else { content }
    }
}
#endif
