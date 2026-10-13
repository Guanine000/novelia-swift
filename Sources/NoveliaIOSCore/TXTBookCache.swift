import CryptoKit
import Foundation
import OSLog

/// TXT 文件请求的来源，每次解码和解析时都会记录。
enum TXTLoadSource: String, Sendable {
    case `import`, download, open, restore
}

/// 已解码并划分章节的 TXT 书籍。`contentHash` 是文件的 SHA-256 十六进制值，
/// 与 `WebDAVFileHash` 的结果一致，因此阅读位置的键保持不变。
struct TXTParsedBook: Sendable {
    let contentHash: String
    let byteCount: Int
    let text: String
    let chapters: [TXTChapter]
    let rulesFingerprint: String
}

/// 每份 TXT 内容只解码和划分章节一次。重复打开或导入相同内容时
/// 复用缓存结果，同一文件的并发请求共享一个任务。
///
/// 缓存层级：文件身份（路径、大小、修改时间）→ 内容哈希；内容哈希 →
/// 解码文本；内容哈希 + 章节规则 → 章节。以内容哈希为键，因此
/// 同一文件的另一份副本（重复导入）也能命中缓存。实际工作在分离任务中运行，
/// actor 仅保护缓存表。
actor TXTBookCache {
    static let shared = TXTBookCache(diskCache: .standard)

    struct FileIdentity: Hashable, Sendable {
        let path: String
        let size: Int
        let modified: Date?
    }

    private struct DecodedText {
        let text: String
        let byteCount: Int
    }

    private struct ParsedKey: Hashable {
        let contentHash: String
        let rulesFingerprint: String
    }

    /// 单次请求的缓存处理结果，供测试和诊断读取。
    struct Statistics: Equatable, Sendable {
        var decodes = 0
        var parses = 0
        var parsedHits = 0
        var decodedHits = 0
        var inFlightJoins = 0
        var diskHits = 0
    }

    private var hashByIdentity: [FileIdentity: String] = [:]
    private var decoded: LRUCache<String, DecodedText>
    private var parsed: LRUCache<ParsedKey, TXTParsedBook>
    private var everDecoded = Set<String>()
    private var everParsed = Set<ParsedKey>()
    private var parsedRulesByHash: [String: Set<String>] = [:]
    private var bookTasks: [String: Task<TXTParsedBook, Error>] = [:]
    private var decodeTasks: [FileIdentity: Task<(hash: String, byteCount: Int), Error>] = [:]
    private(set) var statistics = Statistics()

    /// 限制按文本的 UTF-8 字节数计算；解析后的书籍还保存章节正文
    /// （大约再占同样大小），因此默认值约能保留两本大型小说。
    /// 跨启动保存的章节划分；nil 表示仅保存在内存中（用于测试）。
    private let diskCache: TXTChapterDiskCache?

    init(decodedCostLimit: Int = 48 << 20, parsedCostLimit: Int = 96 << 20, diskCache: TXTChapterDiskCache? = nil) {
        decoded = LRUCache(countLimit: 2, costLimit: decodedCostLimit)
        parsed = LRUCache(countLimit: 2, costLimit: parsedCostLimit)
        self.diskCache = diskCache
    }

    // MARK: 请求

    /// 已解码和解析的书籍，优先从缓存获取。
    func book(at url: URL, rules: TXTChapterRuleConfiguration, source: TXTLoadSource,
              trace: String = DiagnosticContext.newTraceID()) async throws -> TXTParsedBook {
        let start = ContinuousClock.now
        let identity = try Self.identity(of: url)
        let fingerprint = rules.fingerprint
        if let hash = hashByIdentity[identity], let hit = parsed.value(for: ParsedKey(contentHash: hash, rulesFingerprint: fingerprint)) {
            statistics.parsedHits += 1
            logHit(level: "parsed", reason: "reopen", book: hit, source: source, trace: trace, start: start)
            return hit
        }
        let taskKey = "\(identity.path)|\(identity.size)|\(identity.modified?.timeIntervalSince1970 ?? 0)|\(fingerprint)"
        if let running = bookTasks[taskKey] {
            statistics.inFlightJoins += 1
            let book = try await running.value
            logHit(level: "inflight", reason: "concurrent", book: book, source: source, trace: trace, start: start)
            return book
        }
        let knownHash = hashByIdentity[identity]
        let task = Task.detached(priority: .userInitiated) { [self] () throws -> TXTParsedBook in
            do {
                let book = try await self.loadBook(url: url, identity: identity, knownHash: knownHash, rules: rules,
                                                   source: source, trace: trace, start: start)
                await self.finishBookTask(taskKey)
                return book
            } catch {
                await self.finishBookTask(taskKey)
                throw error
            }
        }
        bookTasks[taskKey] = task
        return try await task.value
    }

    /// 仅解码，不划分章节（用于导入校验）。文本保留在缓存中，
    /// 因此随后首次打开只需解析。返回内容哈希。
    @discardableResult
    func validateDecodable(at url: URL, source: TXTLoadSource,
                           trace: String = DiagnosticContext.newTraceID()) async throws -> String {
        let start = ContinuousClock.now
        let identity = try Self.identity(of: url)
        if let hash = hashByIdentity[identity], let hit = decoded.value(for: hash) {
            statistics.decodedHits += 1
            TXTDiagnosticLog.logger.info("TXT cache hit; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(hash), privacy: .public), source=\(source.rawValue, privacy: .public), reason=reopen, level=decoded, cacheHit=true, bytes=\(hit.byteCount, privacy: .public), elapsedMs=\(DiagnosticContext.milliseconds(since: start), privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            return hash
        }
        if let running = decodeTasks[identity] {
            statistics.inFlightJoins += 1
            return try await running.value.hash
        }
        let knownHash = hashByIdentity[identity]
        let task = Task.detached(priority: .utility) { [self] () throws -> (hash: String, byteCount: Int) in
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let hash = knownHash ?? Self.sha256(data)
                await self.remember(hash: hash, for: identity)
                let text = try await self.decodedText(data: data, hash: hash, source: source, trace: trace)
                await self.finishDecodeTask(identity)
                return (hash, text.byteCount)
            } catch {
                await self.finishDecodeTask(identity)
                throw error
            }
        }
        decodeTasks[identity] = task
        return try await task.value.hash
    }

    /// 文件内容的 SHA-256，按文件身份缓存结果。
    func contentHash(of url: URL) async throws -> String {
        let identity = try Self.identity(of: url)
        if let hash = hashByIdentity[identity] { return hash }
        let hash = try await Task.detached(priority: .utility) {
            Self.sha256(try Data(contentsOf: url, options: .mappedIfSafe))
        }.value
        hashByIdentity[identity] = hash
        return hash
    }

    func removeAll() {
        decoded.removeAll()
        parsed.removeAll()
    }

    // MARK: 实际处理（nonisolated：在调用方的分离任务中运行，仅访问缓存表时切回 actor）

    private nonisolated func loadBook(url: URL, identity: FileIdentity, knownHash: String?, rules: TXTChapterRuleConfiguration,
                                      source: TXTLoadSource, trace: String, start: ContinuousClock.Instant) async throws -> TXTParsedBook {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = knownHash ?? Self.sha256(data)
        await remember(hash: hash, for: identity)
        let key = ParsedKey(contentHash: hash, rulesFingerprint: rules.fingerprint)
        // 另一条路径下的相同内容（重复导入或另一份副本）。
        if let hit = await parsedHit(key) {
            await logHit(level: "parsed", reason: "duplicate", book: hit, source: source, trace: trace, start: start)
            return hit
        }
        // 之前启动时保存的章节划分，无需再次解码或解析。
        if let diskCache, let chapters = diskCache.load(hash: hash, rulesFingerprint: key.rulesFingerprint) {
            let book = TXTParsedBook(contentHash: hash, byteCount: data.count, text: "",
                                     chapters: chapters, rulesFingerprint: key.rulesFingerprint)
            await storeDiskHit(book, for: key)
            TXTDiagnosticLog.logger.info("TXT cache hit; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(hash), privacy: .public), source=\(source.rawValue, privacy: .public), reason=launch, level=disk, cacheHit=true, chapters=\(chapters.count, privacy: .public), elapsedMs=\(DiagnosticContext.milliseconds(since: start), privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            return book
        }
        let text = try await decodedText(data: data, hash: hash, source: source, trace: trace)
        let reason = await parseReason(key)
        let parseStart = ContinuousClock.now
        let (chapters, stats) = TXTChapterParser.parseWithStatistics(text.text, rules: rules)
        let tag = DiagnosticContext.bookTag(hash)
        let elapsed = DiagnosticContext.milliseconds(since: parseStart)
        if stats.fellBackToFullText {
            TXTDiagnosticLog.logger.info("TXT chapter detection fell back to full text; trace=\(trace, privacy: .public), book=\(tag, privacy: .public), source=\(source.rawValue, privacy: .public), reason=\(reason, privacy: .public), cacheHit=false, lines=\(stats.lines, privacy: .public), headings=\(stats.headings, privacy: .public), elapsedMs=\(elapsed, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        } else {
            TXTDiagnosticLog.logger.info("TXT chapters parsed; trace=\(trace, privacy: .public), book=\(tag, privacy: .public), source=\(source.rawValue, privacy: .public), reason=\(reason, privacy: .public), cacheHit=false, lines=\(stats.lines, privacy: .public), chapters=\(chapters.count, privacy: .public), elapsedMs=\(elapsed, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        }
        let book = TXTParsedBook(contentHash: hash, byteCount: text.byteCount, text: text.text,
                                 chapters: chapters, rulesFingerprint: key.rulesFingerprint)
        await storeParsed(book, for: key)
        diskCache?.store(chapters, hash: hash, rulesFingerprint: key.rulesFingerprint)
        return book
    }

    private nonisolated func decodedText(data: Data, hash: String, source: TXTLoadSource, trace: String) async throws -> DecodedText {
        let tag = DiagnosticContext.bookTag(hash)
        if let hit = await decodedHit(hash) {
            TXTDiagnosticLog.logger.info("TXT cache hit; trace=\(trace, privacy: .public), book=\(tag, privacy: .public), source=\(source.rawValue, privacy: .public), reason=reopen, level=decoded, cacheHit=true, bytes=\(hit.byteCount, privacy: .public), elapsedMs=0, thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            return hit
        }
        let reason = await decodeReason(hash)
        let decodeStart = ContinuousClock.now
        guard let text = TXTTextDecoder.decode(data: data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            TXTDiagnosticLog.logger.error("TXT decode failed; trace=\(trace, privacy: .public), book=\(tag, privacy: .public), source=\(source.rawValue, privacy: .public), bytes=\(data.count, privacy: .public), elapsedMs=\(DiagnosticContext.milliseconds(since: decodeStart), privacy: .public), attempted=\(TXTTextDecoder.attemptedEncodings, privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            throw TXTTextDecodingError.unrecognizedEncoding
        }
        TXTDiagnosticLog.logger.info("TXT decode succeeded; trace=\(trace, privacy: .public), book=\(tag, privacy: .public), source=\(source.rawValue, privacy: .public), reason=\(reason, privacy: .public), cacheHit=false, bytes=\(data.count, privacy: .public), elapsedMs=\(DiagnosticContext.milliseconds(since: decodeStart), privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        let result = DecodedText(text: text, byteCount: data.count)
        await storeDecoded(result, for: hash)
        return result
    }

    // MARK: 缓存表

    private func parsedHit(_ key: ParsedKey) -> TXTParsedBook? {
        guard let hit = parsed.value(for: key) else { return nil }
        statistics.parsedHits += 1
        return hit
    }

    private func decodedHit(_ hash: String) -> DecodedText? {
        guard let hit = decoded.value(for: hash) else { return nil }
        statistics.decodedHits += 1
        return hit
    }

    private func parseReason(_ key: ParsedKey) -> String {
        if everParsed.contains(key) { return "evicted" }
        return parsedRulesByHash[key.contentHash]?.isEmpty == false ? "rulesChange" : "first"
    }

    private func decodeReason(_ hash: String) -> String {
        everDecoded.contains(hash) ? "evicted" : "first"
    }

    private func storeParsed(_ book: TXTParsedBook, for key: ParsedKey) {
        statistics.parses += 1
        everParsed.insert(key)
        parsedRulesByHash[key.contentHash, default: []].insert(key.rulesFingerprint)
        parsed.insert(book, for: key, cost: Self.cost(of: book))
    }

    private func storeDiskHit(_ book: TXTParsedBook, for key: ParsedKey) {
        statistics.diskHits += 1
        everParsed.insert(key)
        parsedRulesByHash[key.contentHash, default: []].insert(key.rulesFingerprint)
        parsed.insert(book, for: key, cost: Self.cost(of: book))
    }

    /// 文本加章节正文；磁盘命中时没有完整文本，仅有章节正文。
    private static func cost(of book: TXTParsedBook) -> Int {
        book.text.utf8.count + book.chapters.reduce(0) { $0 + $1.body.utf8.count }
    }

    private func storeDecoded(_ text: DecodedText, for hash: String) {
        statistics.decodes += 1
        everDecoded.insert(hash)
        decoded.insert(text, for: hash, cost: text.text.utf8.count)
    }

    private func remember(hash: String, for identity: FileIdentity) {
        hashByIdentity[identity] = hash
    }

    private func finishBookTask(_ key: String) {
        bookTasks[key] = nil
    }

    private func finishDecodeTask(_ identity: FileIdentity) {
        decodeTasks[identity] = nil
    }

    private func logHit(level: String, reason: String, book: TXTParsedBook, source: TXTLoadSource,
                        trace: String, start: ContinuousClock.Instant) {
        TXTDiagnosticLog.logger.info("TXT cache hit; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(book.contentHash), privacy: .public), source=\(source.rawValue, privacy: .public), reason=\(reason, privacy: .public), level=\(level, privacy: .public), cacheHit=true, chapters=\(book.chapters.count, privacy: .public), elapsedMs=\(DiagnosticContext.milliseconds(since: start), privacy: .public), thread=\(DiagnosticContext.threadLabel, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
    }

    // MARK: 辅助方法

    static func identity(of url: URL) throws -> FileIdentity {
        let standardized = url.standardizedFileURL
        let values = try standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileIdentity(path: standardized.path, size: values.fileSize ?? 0, modified: values.contentModificationDate)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 磁盘上的章节划分，以内容哈希、章节规则和解析器版本为键，
/// 使后续启动可以直接打开大型 TXT，无需重新解码或解析。保存在 Caches 中
/// （系统可能清理），仅保留最近使用的书籍。
///
/// 文件格式：4 字节小端序头部长度、JSON 头部（标题、卷名、正文 UTF-8 长度），
/// 随后连续存放正文 UTF-8 字节。任何不匹配都视为缓存未命中。
struct TXTChapterDiskCache: Sendable {
    /// 解析器或格式变化导致已存章节划分的含义改变时，递增此版本。
    static let formatVersion = 1
    static let standard = TXTChapterDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TXTChapters", isDirectory: true))

    let directory: URL
    var maximumBooks = 8

    private struct Header: Codable {
        var version: Int
        var hash: String
        var rules: String
        var chapters: [Entry]
    }

    private struct Entry: Codable {
        var title: String
        var volume: String?
        var bytes: Int
    }

    func fileURL(hash: String, rulesFingerprint: String) -> URL {
        let rules = TXTBookCache.sha256(Data("\(Self.formatVersion)|\(rulesFingerprint)".utf8)).prefix(16)
        return directory.appendingPathComponent("\(hash)-\(rules).txtchapters")
    }

    func load(hash: String, rulesFingerprint: String) -> [TXTChapter]? {
        let url = fileURL(hash: hash, rulesFingerprint: rulesFingerprint)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 4 else { return nil }
        let headerLength = data.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard headerLength > 0, 4 + headerLength <= data.count,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 4..<(4 + headerLength))),
              header.version == Self.formatVersion, header.hash == hash, header.rules == rulesFingerprint,
              header.chapters.allSatisfy({ $0.bytes >= 0 }),
              header.chapters.reduce(0, { $0 + $1.bytes }) == data.count - 4 - headerLength else { return nil }
        var cursor = 4 + headerLength
        var chapters: [TXTChapter] = []
        chapters.reserveCapacity(header.chapters.count)
        for (index, entry) in header.chapters.enumerated() {
            guard let body = String(data: data.subdata(in: cursor..<(cursor + entry.bytes)), encoding: .utf8) else { return nil }
            chapters.append(TXTChapter(index: index, title: entry.title, body: body, volumeTitle: entry.volume))
            cursor += entry.bytes
        }
        // 标记为最近使用，供淘汰策略参考。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return chapters
    }

    func store(_ chapters: [TXTChapter], hash: String, rulesFingerprint: String) {
        let bodies = chapters.map { Data($0.body.utf8) }
        let header = Header(version: Self.formatVersion, hash: hash, rules: rulesFingerprint,
                            chapters: zip(chapters, bodies).map { Entry(title: $0.title, volume: $0.volumeTitle, bytes: $1.count) })
        guard let headerData = try? JSONEncoder().encode(header) else { return }
        var data = Data(capacity: 4 + headerData.count + bodies.reduce(0) { $0 + $1.count })
        withUnsafeBytes(of: UInt32(headerData.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(headerData)
        bodies.forEach { data.append($0) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(hash: hash, rulesFingerprint: rulesFingerprint), options: .atomic)
            evict()
        } catch {
            let nsError = error as NSError
            TXTDiagnosticLog.logger.error("TXT chapter cache write failed; domain=\(ShareableLogPolicy.domainLabel(nsError.domain), privacy: .public), code=\(nsError.code, privacy: .public)")
        }
    }

    private func evict() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter({ $0.pathExtension == "txtchapters" }), files.count > maximumBooks else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maximumBooks) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
