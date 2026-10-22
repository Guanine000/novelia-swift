import Foundation

/// 书籍字数的统计口径，书库与阅读器目录共用。仿 Word 的“字数”：
/// 每个中日文字符（汉字、假名、全角字符与中文标点）计 1；其余连续的非空白字符
/// （英文单词、数字、韩文词、emoji 等）合计 1；空白不计。弯引号、破折号、省略号、间隔号
/// 紧跟在单词后时并入该词，否则单独计 1，避免英文缩写被拆开、中文标点被漏算。
/// 口径改变时提高 `ruleVersion`，使旧缓存失效。
public enum BookWordCount {
    public static let ruleVersion = 1

    public static func count<S: StringProtocol>(text: S) -> Int {
        var total = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if isAttached(scalar) {
                continue
            } else if isEastAsian(scalar) {
                total += 1
                inWord = false
            } else if isSharedPunctuation(scalar) {
                if !inWord { total += 1 }
            } else if !inWord {
                total += 1
                inWord = true
            }
        }
        return total
    }

    /// XHTML 章节的字数：去掉 head/script/style、注释和注音（`<rt>`／`<rp>`），标签视为分隔，
    /// 实体按解码后的字符计算。图片的替代文字不计入。
    public static func count(html: String) -> Int {
        var text = html
        for pattern in [#"(?is)<head\b.*?</head\s*>"#, #"(?is)<(script|style)\b.*?</\1\s*>"#, #"(?s)<!--.*?-->"#,
                        #"(?is)<(rt|rp)\b[^>]*>.*?</\1\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        return count(text: BookTextSearch.decodeEntities(text))
    }

    /// TXT 一章的字数：标题加正文（卷名另起一行，不重复计入每章）。分章器生成的“全文”“前言”
    /// 不在原文中，不计入，使各章之和与全书字数一致；原文中真有“前言”标题时少计这两个字。
    static func count(chapter: TXTChapter) -> Int {
        (generatedTXTTitles.contains(chapter.title) ? 0 : count(text: chapter.title)) + count(text: chapter.body)
    }

    private static let generatedTXTTitles: Set = ["全文", "前言"]

    /// 目录各条目的字数：从条目所在的分页单位（EPUB spine 项）起，到下一个位置更靠后的条目之前。
    /// 没有位置或与前面的条目指向同一单位的条目为 nil（同一文件内的锚点无法拆分字数）。
    public static func tocCounts(entrySpines: [Int?], chapterCounts: [Int]) -> [Int?] {
        var seen = Set<Int>()
        return entrySpines.enumerated().map { index, spine in
            guard let spine, chapterCounts.indices.contains(spine), seen.insert(spine).inserted else { return nil }
            let next = entrySpines[(index + 1)...].lazy.compactMap { $0 }.first { $0 > spine }
            let end = min(next ?? chapterCounts.count, chapterCounts.count)
            return chapterCounts[spine..<end].reduce(0, +)
        }
    }

    /// 例如“8532字”“32.5万字”“1.2亿字”。
    public static func format(_ count: Int) -> String {
        func scaled(_ unit: Double, _ suffix: String) -> String {
            let value = (Double(count) / unit * 10).rounded() / 10
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return text + suffix
        }
        if count >= 100_000_000 { return scaled(100_000_000, "亿字") }
        if count >= 10_000 { return scaled(10_000, "万字") }
        return "\(count)字"
    }

    /// 组合附标、变体选择符与零宽连接符等格式字符：附着在前一个字符上，不单独计数。
    private static func isAttached(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: true
        default: false
        }
    }

    private static func isEastAsian(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF,   // 部首、汉字结构描述符
             0x3000...0x303F,   // 中日文符号与标点
             0x3040...0x31FF,   // 假名、注音、笔画
             0x3200...0x33FF,   // 带圈与兼容字符
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFE10...0xFE1F, 0xFE30...0xFE4F, // 竖排与兼容标点
             0xFF00...0xFFEF,   // 全角与半角形式
             0x20000...0x3FFFF: // 扩展汉字
            true
        default:
            false
        }
    }

    /// 中英文共用的标点：· ‐–—― ‘’‚‛“”„‟ … ⸺⸻。
    private static func isSharedPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00B7, 0x2010...0x2015, 0x2018...0x201F, 0x2026, 0x2E3A, 0x2E3B: true
        default: false
        }
    }
}

/// 一本书的字数：`chapters` 为 EPUB 每个 spine 项的字数；TXT 只保存全书字数（章节随分章规则变化，阅读时现算）。
public struct BookWordCounts: Codable, Equatable, Sendable {
    public var total: Int
    public var chapters: [Int]

    public init(total: Int, chapters: [Int] = []) {
        self.total = total
        self.chapters = chapters
    }
}

/// 以文件内容哈希为键的字数缓存，书库与阅读器共用。内容哈希与阅读位置的键一致，
/// 同一内容的副本命中同一结果；同一哈希的并发请求共享一次统计。
/// 结果写在 Caches 目录，属于可重建数据：口径版本不符、解码失败或被系统清理时重新统计；
/// 超过 `fileLimit` 个文件时删除最久未写入的条目。不参与同步，也不写入书库索引。
actor BookWordCountCache {
    static let shared = BookWordCountCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookWordCounts", isDirectory: true))

    private struct Entry: Codable {
        let version: Int
        let counts: BookWordCounts
    }

    /// nil 表示仅保存在内存中（用于测试）。
    private let directory: URL?
    private let fileLimit: Int
    private var memory: [String: BookWordCounts] = [:]
    private var tasks: [String: Task<BookWordCounts, Error>] = [:]

    init(directory: URL?, fileLimit: Int = 2000) {
        self.directory = directory
        self.fileLimit = fileLimit
    }

    /// 已统计过的结果（内存或磁盘），不触发统计。
    func cached(hash: String) -> BookWordCounts? {
        if let hit = memory[hash] { return hit }
        guard let url = fileURL(hash: hash), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == BookWordCount.ruleVersion else { return nil }
        memory[hash] = entry.counts
        return entry.counts
    }

    /// 缓存命中时直接返回，否则执行 `compute`（调用方负责把重活放到后台）并保存结果。
    /// 统计失败不缓存，下次请求重试。
    func counts(hash: String, compute: @escaping @Sendable () async throws -> BookWordCounts) async throws -> BookWordCounts {
        if let hit = cached(hash: hash) { return hit }
        if let running = tasks[hash] { return try await running.value }
        let task = Task { try await compute() }
        tasks[hash] = task
        defer { tasks[hash] = nil }
        let counts = try await task.value
        store(counts, hash: hash)
        return counts
    }

    private func store(_ counts: BookWordCounts, hash: String) {
        memory[hash] = counts
        guard let directory, let url = fileURL(hash: hash),
              let data = try? JSONEncoder().encode(Entry(version: BookWordCount.ruleVersion, counts: counts)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        evict(directory)
    }

    private func evict(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > fileLimit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - fileLimit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 只接受十六进制哈希作为文件名，避免路径穿越。
    private func fileURL(hash: String) -> URL? {
        guard let directory, !hash.isEmpty, hash.allSatisfy(\.isHexDigit) else { return nil }
        return directory.appendingPathComponent(hash.lowercased() + ".json")
    }
}
