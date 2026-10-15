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

