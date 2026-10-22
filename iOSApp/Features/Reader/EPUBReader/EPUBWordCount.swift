import Foundation
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

// MARK: - 字数统计（书库与目录共用，口径见 `BookWordCount`）

extension EPUBContainer {
    /// 打开一份独立的容器逐个统计 spine 项：不与阅读器正在使用的容器共享诊断计数，可在后台执行。
    /// 读取失败的章节计 0，不让一章出错使整本书没有字数；取消时抛出 `CancellationError`。
    static func wordCounts(fileURL: URL) async throws -> BookWordCounts {
        let container = try await open(fileURL: fileURL)
        var chapters: [Int] = []
        chapters.reserveCapacity(container.spine.count)
        for index in container.spine.indices {
            try Task.checkCancellation()
            let html = try? await container.chapterHTML(at: index)
            chapters.append(html.map(BookWordCount.count(html:)) ?? 0)
        }
        return BookWordCounts(total: chapters.reduce(0, +), chapters: chapters)
    }
}
