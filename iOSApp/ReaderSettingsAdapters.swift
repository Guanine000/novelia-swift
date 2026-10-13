import SwiftUI

extension ReaderSettings {
    var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .system }
    var backgrounds: ReaderBackgroundStore { .shared }

    /// Keep chapter indices and EPUB offsets separate while sharing their access point.
    func recordWebPosition(id: String, chapterIndex: Int) {
        ReadingPositionSync.recordWeb(id: id, chapterIndex: chapterIndex)
    }

    /// `chapterOffset` is YueduCoreText-only; `chapterProgression` is written by both engines.
    func recordEPUBPosition(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?) {
        ReadingPositionSync.recordEPUB(hash: hash, fraction: fraction, spineIndex: spineIndex,
                                       chapterOffset: chapterOffset, chapterProgression: chapterProgression)
    }

    func epubPosition(hash: String) -> SyncedReadingPosition? {
        ReadingPositionSync.epubPosition(hash: hash)
    }
}
