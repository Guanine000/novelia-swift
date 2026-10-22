import Foundation

/// 本机书籍的字数入口，书库与阅读器目录共用：按文件内容哈希读 `BookWordCountCache`，
/// 未命中时在后台统计并写回。只读取书籍文件，不修改书籍、索引或阅读状态。
/// TXT 直接解码文件而不经过 `TXTBookCache`，避免书库批量统计挤掉正在阅读的书的缓存。
enum BookWordCounter {
    static func counts(fileURL: URL, format: WebNovelFileFormat, hash: String) async throws -> BookWordCounts {
        try await BookWordCountCache.shared.counts(hash: hash) {
            try await Task.detached(priority: .utility) {
                switch format {
                case .epub:
                    return try await EPUBContainer.wordCounts(fileURL: fileURL)
                case .txt:
                    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    try Task.checkCancellation()
                    guard let text = TXTTextDecoder.decode(data: data) else { throw TXTTextDecodingError.unrecognizedEncoding }
                    return BookWordCounts(total: BookWordCount.count(text: text))
                }
            }.value
        }
    }

    static func cached(hash: String) async -> BookWordCounts? {
        await BookWordCountCache.shared.cached(hash: hash)
    }

    /// TXT 目录各章字数（与分章规则有关，不缓存）及全书字数；在后台计算。
    static func txtTOCCounts(_ book: TXTParsedBook) async -> ReaderTOCWordCounts {
        let total = try? await BookWordCountCache.shared.counts(hash: book.contentHash) {
            await Task.detached(priority: .utility) { BookWordCounts(total: BookWordCount.count(text: book.text)) }.value
        }
        let chapters = await Task.detached(priority: .utility) { book.chapters.map(BookWordCount.count(chapter:)) }.value
        return ReaderTOCWordCounts(total: total?.total ?? chapters.reduce(0, +), entries: chapters)
    }

    /// EPUB 目录各条目的字数，条目按 spine 序号对应（见 `BookWordCount.tocCounts`）。
    static func epubTOCCounts(fileURL: URL, hash: String, entrySpines: [Int?]) async -> ReaderTOCWordCounts? {
        guard let counts = try? await counts(fileURL: fileURL, format: .epub, hash: hash) else { return nil }
        return ReaderTOCWordCounts(total: counts.total,
                                   entries: BookWordCount.tocCounts(entrySpines: entrySpines, chapterCounts: counts.chapters))
    }
}

/// 阅读器目录显示的字数：`entries` 与目录条目一一对应，nil 表示该条目不显示字数。
struct ReaderTOCWordCounts: Equatable, Sendable {
    var total: Int
    var entries: [Int?]

    init(total: Int, entries: [Int?]) {
        self.total = total
        self.entries = entries
    }

    init(total: Int, entries: [Int]) {
        self.init(total: total, entries: entries.map(Optional.some))
    }

    func entry(_ index: Int) -> String? {
        entries.indices.contains(index) ? entries[index].map(BookWordCount.format) : nil
    }
}
