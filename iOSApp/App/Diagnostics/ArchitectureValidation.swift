// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import Foundation
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
            for name in ["Library", "WebNovelDownloads", "WenkuEPUB", "ReadingStatistics", "Bookmarks"] {
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
            let text = "第一章 起点\n" + String(repeating: "本地TXT验证正文，通过原有分章和Readium管线阅读。\n\n", count: 80)
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
            statistics: ReadingStatisticsStore(defaults: .standard, deviceIDs: credentials,
                                                directory: support.appendingPathComponent("ReadingStatistics")),
            blockedTags: BlockedTagsStore(defaults: .standard),
            backgrounds: ReaderBackgroundStore(defaults: .standard, directory: support.appendingPathComponent("ReaderBackgrounds")),
            cloudBooks: CloudBookStore(directory: support.appendingPathComponent("WebDAVCloudBooks")),
            passwordStore: WebDAVPasswordStore(load: { credentials.password }, save: { credentials.password = $0 }))
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
        return AppServices(configuration: configuration, api: backend.services(), account: account,
            forumAccount: forum, local: local, performsUpdateChecks: false)
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

/// 显示验证进程的外部请求计数，供自动化读取；不参与业务交互且不进入 Release。
struct ArchitectureValidationIndicator: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("验证环境 · 外部请求 \(ArchitectureNetworkTrap.count) · 正文请求 \(ArchitectureNetworkTrap.chapterCount) · 本机正文 \(ArchitectureNetworkTrap.localDocumentCount) · 批次 \(ArchitectureNetworkTrap.batchCount) · EPUB请求 \(ArchitectureNetworkTrap.downloadCount)")
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
#endif
