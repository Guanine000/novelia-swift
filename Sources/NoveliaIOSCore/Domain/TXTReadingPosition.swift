// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct TXTReadingPosition: Codable, Equatable {
    public var chapter: Int
    public var unit: Int?
    public var offset: Int?
    public var unitCount: Int?

    /// 0.12.0（52）使用的本地专属键；阅读位置现在保存在可同步的阅读位置中。
    public static func legacyKey(hash: String) -> String { "txtReadingPosition.v1.\(hash)" }

    public static func legacy(hash: String, defaults: UserDefaults = .standard) -> TXTReadingPosition? {
        defaults.data(forKey: legacyKey(hash: hash)).flatMap { try? JSONDecoder().decode(TXTReadingPosition.self, from: $0) }
    }

    /// 滚动阅读器移动到 `chapter`；保留该章节内的分页位置。
    public func movingToChapter(_ chapter: Int) -> TXTReadingPosition {
        chapter == self.chapter ? self : TXTReadingPosition(chapter: chapter)
    }

    public init(chapter: Int, unit: Int? = nil, offset: Int? = nil, unitCount: Int? = nil) {
        self.chapter = chapter; self.unit = unit; self.offset = offset; self.unitCount = unitCount
    }
}
