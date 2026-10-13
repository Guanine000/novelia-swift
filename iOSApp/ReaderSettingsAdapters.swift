import SwiftUI

extension ReaderSettings {
    var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .system }
    var backgrounds: ReaderBackgroundStore { .shared }

    /// 共用访问入口，同时分别处理章节序号与 EPUB 偏移量。
    func recordWebPosition(id: String, chapterIndex: Int) {
        ReadingPositionSync.recordWeb(id: id, chapterIndex: chapterIndex)
    }

    /// `chapterOffset` 仅由 YueduCoreText 使用；`chapterProgression` 由两个引擎写入。
    func recordEPUBPosition(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?) {
        ReadingPositionSync.recordEPUB(hash: hash, fraction: fraction, spineIndex: spineIndex,
                                       chapterOffset: chapterOffset, chapterProgression: chapterProgression)
    }

    func epubPosition(hash: String) -> SyncedReadingPosition? {
        ReadingPositionSync.epubPosition(hash: hash)
    }
}
