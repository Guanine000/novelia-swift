// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// LocalAppServices 持有的本地进度存储，阅读与同步通过同一实例访问。
/// 保留 readingPositions.v1、web/epub/txt 身份和旧位置读取；位置转换由阅读引擎负责。
/// 首次读取后在内存保留全部位置，翻页记录不再重复解码；写入仍立即落盘，异常退出不丢进度。
/// 缓存只对本实例有效，同一偏好存储不得再创建第二个实例写入进度。
@MainActor
final class ReadingPositionStore: ReadingPositionSynchronizing {
    private let defaults: UserDefaults
    private var cache: [String: SyncedReadingPosition]?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private static let key = "readingPositions.v1"

    func all() -> [String: SyncedReadingPosition] {
        if let cache { return cache }
        let loaded = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: SyncedReadingPosition].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    func recordWeb(id: String, chapterIndex: Int) {
        var positions = all()
        positions["web:\(id)"] = SyncedReadingPosition(chapterIndex: chapterIndex, fraction: nil, updatedAt: Date())
        save(positions)
    }

    func recordEPUB(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?) {
        var positions = all()
        positions["epub:\(hash)"] = SyncedReadingPosition(chapterIndex: spineIndex,
            fraction: min(1, max(0, fraction)), updatedAt: Date(), chapterOffset: chapterOffset,
            chapterProgression: chapterProgression.map { min(1, max(0, $0)) })
        save(positions)
    }

    func epubPosition(hash: String) -> SyncedReadingPosition? { all()["epub:\(hash)"] }

    /// 滚动和分页阅读器共用的 TXT 阅读位置，以书籍文件哈希同步。
    func recordTXT(hash: String, position: TXTReadingPosition) {
        var positions = all()
        positions["txt:\(hash)"] = SyncedReadingPosition(chapterIndex: position.chapter, fraction: nil, updatedAt: Date(),
            chapterOffset: position.offset, unit: position.unit, unitCount: position.unitCount)
        save(positions)
    }

    func txtPosition(hash: String) -> TXTReadingPosition? {
        if let synced = all()["txt:\(hash)"], let chapter = synced.chapterIndex {
            return TXTReadingPosition(chapter: chapter, unit: synced.unit, offset: synced.chapterOffset, unitCount: synced.unitCount)
        }
        // 0.12.0（52）测试构建将 TXT 阅读位置保存在仅本地使用的键中。
        return TXTReadingPosition.legacy(hash: hash, defaults: defaults)
    }

    @discardableResult
    func pruneFilePositions(keepingHashes: Set<String>, olderThan cutoff: Date) -> Int {
        let positions = all()
        let kept = positions.filter { key, position in
            guard let hash = Self.fileHash(fromKey: key) else { return true }
            return keepingHashes.contains(hash) || position.updatedAt >= cutoff
        }
        save(kept)
        return positions.count - kept.count
    }

    /// `epub:<哈希>` 与 `txt:<哈希>` 的文件哈希；其他身份返回 nil。
    private static func fileHash(fromKey key: String) -> String? {
        for prefix in ["epub:", "txt:"] where key.hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
        return nil
    }

    func merge(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        var positions = all()
        let progress = ReadingProgressStore(defaults: defaults)
        for book in webBooks {
            let key = "web:\(book.id)"
            if positions[key] == nil, let index = progress.chapterIndex(novelID: book.id) {
                positions[key] = SyncedReadingPosition(
                    chapterIndex: index, fraction: nil,
                    updatedAt: progress.updatedAt(novelID: book.id) ?? .distantPast)
            }
        }
        positions = SyncedReadingPosition.merged(positions, remote)
        for book in webBooks {
            if let position = positions["web:\(book.id)"], let index = position.chapterIndex {
                progress.save(chapterIndex: index, updatedAt: position.updatedAt, novelID: book.id)
            }
        }
        save(positions)
    }

    private func save(_ positions: [String: SyncedReadingPosition]) {
        guard positions != cache else { return }
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: Self.key)
            cache = positions
        }
    }
}


/// 书籍已不在书库（本机与云端）时，清理阅读器只在本机保存的附加记录。
/// 键前缀须与 Readium 阅读器写入的一致（ReadiumEPUBReaderModel、ReadiumTextPublication）。
enum ReaderLocalCleanup {
    /// EPUB：`<前缀><文件哈希>`。
    static let readiumBookPrefixes = ["readium.locator.v1.", "readium.locatorTime.v1."]
    /// TXT：`<前缀>txt|<文件哈希>|<分章规则指纹>`。
    static let readiumTextPrefixes = ["readium.text.locator.v1.", "readium.text.time.v1."]

    /// Readium 精确位置只用于本机快速恢复，书不在书库时没有用处；共享阅读位置另按时间清理。
    static func orphanedReadiumKeys(_ keys: some Sequence<String>, keepingHashes: Set<String>) -> [String] {
        keys.filter { key in
            if let prefix = readiumBookPrefixes.first(where: key.hasPrefix) {
                return !keepingHashes.contains(String(key.dropFirst(prefix.count)))
            }
            if let prefix = readiumTextPrefixes.first(where: key.hasPrefix) {
                let parts = key.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "txt" else { return false }
                return !keepingHashes.contains(String(parts[1]))
            }
            return false
        }
    }
}
