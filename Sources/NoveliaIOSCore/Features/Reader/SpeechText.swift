import Foundation

/// 朗读文本准备：把章节纯文本切成交给系统语音合成逐句播放的片段，并支持按章内比例定位起播句。
/// 只做纯计算，不持有发声对象或音频会话；平台发声、音频焦点与后台播放由 App 层适配，
/// 因此两个 App 目标（含 iOS 15 Legacy）共用同一套切分口径。
/// 偏移使用 UTF-16，与 `BookTextSearch`、`EPUBChapterProgress.textLength` 和阅读进度一致。
enum SpeechText {
    struct Segment: Equatable, Sendable {
        /// 交给语音合成的文本；首尾空白已去掉，段落内空白合并为单个空格。
        let text: String
        /// 片段首字符在章节纯文本中的 UTF-16 偏移。
        let utf16Offset: Int
        /// 合成文本每个 UTF-16 单元在原文中的位置，保留折叠空白前的精确对应。
        let sourceUTF16Offsets: [Int]

        init(text: String, utf16Offset: Int, sourceUTF16Offsets: [Int]? = nil) {
            self.text = text
            self.utf16Offset = utf16Offset
            self.sourceUTF16Offsets = sourceUTF16Offsets ?? Array(utf16Offset..<(utf16Offset + text.utf16.count))
        }

        var sourceRange: Range<Int> { utf16Offset..<((sourceUTF16Offsets.last ?? utf16Offset) + 1) }

        func sourceOffset(forSpokenOffset offset: Int) -> Int {
            guard !sourceUTF16Offsets.isEmpty else { return utf16Offset }
            return sourceUTF16Offsets[min(max(0, offset), sourceUTF16Offsets.count - 1)]
        }
    }

    /// 单段字面上限。系统合成对超长文本容易中断，先按句末标点切，再对无标点长文兜底切分。
    static let maxSegmentLength = 200

    private static let sentenceEnds: Set<Character> = ["。", "．", "！", "？", "；", "…", ".", "!", "?", ";"]
    /// 句末标点后紧跟的闭合引号／括号仍属于本句，避免把引号单独读成一个片段。
    private static let trailers: Set<Character> = ["」", "』", "”", "\"", "'", "）", ")", "】", "》"]

    /// 按中英文句末标点与换行切句；连续标点和闭合符号归入当前句，段落内空白合并。
    static func segments(in text: String) -> [Segment] {
        let characters = Array(text)
        var result: [Segment] = []
        var buffer = ""
        var offsets: [Int] = []
        var bufferStart = 0
        var cursor = 0
        var index = 0

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var leading = 0
                for character in buffer {
                    guard character.isWhitespace else { break }
                    leading += character.utf16.count
                }
                let mapping = Array(offsets.dropFirst(leading).prefix(trimmed.utf16.count))
                result.append(Segment(text: trimmed, utf16Offset: mapping.first ?? bufferStart + leading,
                                      sourceUTF16Offsets: mapping))
            }
            buffer.removeAll(keepingCapacity: true)
            offsets.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]
            let width = character.utf16.count

            // 换行是段落边界，即使上一句没有标点也要断开。
            if character.isNewline {
                flush()
                cursor += width
                index += 1
                continue
            }
            if character.isWhitespace {
                if !buffer.isEmpty && !buffer.hasSuffix(" ") { buffer.append(" "); offsets.append(cursor) }
                cursor += width
                index += 1
                continue
            }

            if buffer.isEmpty { bufferStart = cursor }
            // 段落内合并的空格不应留在句末标点之前；开引号前的空格要保留。
            if buffer.hasSuffix(" "), sentenceEnds.contains(character) {
                buffer.removeLast()
                offsets.removeLast()
            }
            buffer.append(character)
            offsets.append(contentsOf: cursor..<(cursor + width))
            cursor += width
            index += 1

            if sentenceEnds.contains(character) {
                while index < characters.count {
                    let next = characters[index]
                    guard sentenceEnds.contains(next) || trailers.contains(next) else { break }
                    buffer.append(next)
                    offsets.append(contentsOf: cursor..<(cursor + next.utf16.count))
                    cursor += next.utf16.count
                    index += 1
                }
                flush()
            } else if buffer.utf16.count >= maxSegmentLength {
                // 无标点长文按上限硬切，保证不丢字符，也不让单次合成过长。
                flush()
            }
        }
        flush()
        return result
    }

    /// 显示块/长文本切片在原文中的顺序范围；重复文本从上次匹配之后查找。
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

    /// DOM 可见字符按去空白后的 UTF-16 位置映射，正文引文必须匹配，否则拒绝猜位置。
    static func sourceOffset(visibleNonWhitespaceOffset: Int, quote: String, in text: String) -> Int? {
        var normalized = "", offsets: [Int] = [], sourceOffset = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf16.count
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                offsets += Array(sourceOffset..<(sourceOffset + count))
            }
            sourceOffset += count
        }
        let needle = String(String.UnicodeScalarView(quote.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
        let source = normalized as NSString
        guard visibleNonWhitespaceOffset >= 0, visibleNonWhitespaceOffset < offsets.count, !needle.isEmpty,
              source.substring(from: visibleNonWhitespaceOffset).hasPrefix(needle) else { return nil }
        return offsets[visibleNonWhitespaceOffset]
    }

    /// 页首可以位于长句中间：拆出可见位置，保留前缀供上一句/段回退，不倒退到句首。
    static func splitAtVisibleOffset(_ segments: [Segment], offset: Int?) -> [Segment] {
        guard let offset, let index = segments.firstIndex(where: { $0.sourceRange.contains(offset) }) else { return segments }
        let segment = segments[index]
        guard var cut = segment.sourceUTF16Offsets.firstIndex(where: { $0 >= offset }), cut > 0 else { return segments }
        let source = segment.text as NSString
        if (0xDC00...0xDFFF).contains(source.character(at: cut)) { cut -= 1 }
        guard cut > 0 else { return segments }
        let left = Segment(text: source.substring(to: cut), utf16Offset: segment.utf16Offset,
                           sourceUTF16Offsets: Array(segment.sourceUTF16Offsets[..<cut]))
        let right = Segment(text: source.substring(from: cut), utf16Offset: segment.sourceUTF16Offsets[cut],
                            sourceUTF16Offsets: Array(segment.sourceUTF16Offsets[cut...]))
        var result = segments
        result.replaceSubrange(index...index, with: [left, right])
        return result
    }
    static func selectedOffset(_ selected: String, in text: String, near progression: Double) -> Int? {
        let source = text as NSString
        let needle = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        var found: [Int] = [], cursor = 0
        while cursor < source.length {
            let range = source.range(of: needle, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound else { break }
            found.append(range.location); cursor = NSMaxRange(range)
        }
        let target = Double(source.length) * (progression.isFinite ? min(1, max(0, progression)) : 0)
        return found.min { abs(Double($0) - target) < abs(Double($1) - target) }
    }
    static func localRange(_ range: Range<Int>?, in sourceRange: Range<Int>) -> Range<Int>? {
        guard let range else { return nil }
        let start = max(range.lowerBound, sourceRange.lowerBound)
        let end = min(range.upperBound, sourceRange.upperBound)
        return end > start ? (start - sourceRange.lowerBound)..<(end - sourceRange.lowerBound) : nil
    }

    /// 从章内比例（0–1）找起播片段：返回覆盖该位置的片段下标。
    /// 比例无效、章节长度未知时从章首开始；比例落在片段间的空白时从下一片段开始。
    static func startIndex(in segments: [Segment], chapterUTF16Length: Int, progression: Double) -> Int {
        guard !segments.isEmpty, chapterUTF16Length > 0, progression.isFinite else { return 0 }
        let fraction = min(max(progression, 0), 1)
        let target = min(chapterUTF16Length - 1, Int((fraction * Double(chapterUTF16Length)).rounded(.down)))
        for (index, segment) in segments.enumerated() {
            let nextOffset = index + 1 < segments.count ? segments[index + 1].utf16Offset : chapterUTF16Length
            if segment.utf16Offset <= target, target < nextOffset { return index }
            if segment.utf16Offset > target { return index }
        }
        return segments.count - 1
    }
}
