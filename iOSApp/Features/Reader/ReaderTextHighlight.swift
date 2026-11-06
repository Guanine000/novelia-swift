import Foundation
import SwiftUI

/// 正文块与搜索命中之间的偏移换算。偏移一律是 UTF-16，与 `BookTextSearch` 和阅读进度一致。
enum ReaderTextRanges {
    /// 各显示块在整章正文中的顺序范围；重复文本从上次匹配之后继续找。
    static func sourceRanges(of pieces: [String], in text: String) -> [Range<Int>?] {
        let source = text as NSString
        var cursor = 0
        return pieces.map { piece in
            guard !piece.isEmpty else { return nil }
            let range = source.range(of: piece, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound else { return nil }
            cursor = NSMaxRange(range)
            return range.location..<cursor
        }
    }

    /// 把整章偏移收窄到某个显示块内的本地偏移；没有交集时返回 nil。
    static func localRange(_ range: Range<Int>?, in sourceRange: Range<Int>) -> Range<Int>? {
        guard let range else { return nil }
        let start = max(range.lowerBound, sourceRange.lowerBound)
        let end = min(range.upperBound, sourceRange.upperBound)
        return end > start ? (start - sourceRange.lowerBound)..<(end - sourceRange.lowerBound) : nil
    }
}

/// 给已有正文附加搜索命中底色；不改变正文字符、字体或链接渲染入口。
enum ReaderTextHighlight {
    static func apply(_ range: Range<Int>?, text: String, to value: inout AttributedString) {
        guard let range, range.lowerBound >= 0, range.upperBound <= text.utf16.count,
              let stringRange = Range(NSRange(location: range.lowerBound, length: range.count), in: text),
              let lower = AttributedString.Index(stringRange.lowerBound, within: value),
              let upper = AttributedString.Index(stringRange.upperBound, within: value) else { return }
        value[lower..<upper].backgroundColor = Color.yellow.opacity(0.35)
    }
}
