import SwiftUI

extension ReaderSettings {
    var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .system }
    var backgrounds: ReaderBackgroundStore { .shared }

    /// Keep chapter indices and EPUB offsets separate while sharing their access point.
    func recordWebPosition(id: String, chapterIndex: Int) {
        ReadingPositionSync.recordWeb(id: id, chapterIndex: chapterIndex)
    }

    func recordEPUBPosition(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?) {
        ReadingPositionSync.recordEPUB(hash: hash, fraction: fraction, spineIndex: spineIndex, chapterOffset: chapterOffset)
    }

    func epubPosition(hash: String) -> SyncedReadingPosition? {
        ReadingPositionSync.epubPosition(hash: hash)
    }
}
