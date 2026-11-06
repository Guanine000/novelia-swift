import Foundation
import XCTest
@testable import NoveliaIOSCore

final class SpeechTextTests: XCTestCase {
    func testSelectedTextUsesClosestRepeatedOccurrenceAndExactOffsetAnchor() {
        let source = "相同句。中间句。相同句。"
        XCTAssertEqual(SpeechText.selectedOffset("相同句。", in: source, near: 0), 0)
        XCTAssertEqual(SpeechText.selectedOffset("相同句。", in: source, near: 0.9), 8)
        XCTAssertNil(SpeechText.selectedOffset("没有的句子", in: source, near: 0))
        let anchor = SpeechAnchor(chapterIndex: 0, progression: 0, chapterUTF16Length: 0,
                                  startIndexHint: nil, sourceUTF16Offset: 8)
        XCTAssertGreaterThan(anchor.resolvedProgression(length: source.utf16.count), 0.66)
    }

    func testSplitsMixedSentencesAndAbsorbsTrailingPunctuation() {
        let text = "第一句。第二句！他说：「你好。」\n第三段？"
        XCTAssertEqual(SpeechText.segments(in: text).map(\.text),
                       ["第一句。", "第二句！", "他说：「你好。」", "第三段？"])

        let latin = "Hello world. Really?! He said \"done.\" Next"
        XCTAssertEqual(SpeechText.segments(in: latin).map(\.text),
                       ["Hello world.", "Really?!", "He said \"done.\"", "Next"])
    }

    func testOffsetsUseUTF16AndMatchTheSourceText() {
        let text = "甲乙。丙丁！"
        let segments = SpeechText.segments(in: text)
        XCTAssertEqual(segments.map(\.utf16Offset), [0, 3])
        XCTAssertEqual(segments.map(\.text), ["甲乙。", "丙丁！"])

        let withEmoji = "😀一句。后面！"
        let emojiSegments = SpeechText.segments(in: withEmoji)
        XCTAssertEqual(emojiSegments.count, 2)
        XCTAssertEqual(emojiSegments[1].utf16Offset, 5, "surrogate pairs count as two UTF-16 units")
        XCTAssertEqual(emojiSegments[1].text, "后面！")
    }

    func testLongTextWithoutPunctuationIsSplitWithoutLosingCharacters() {
        let text = String(repeating: "字", count: 470)
        let segments = SpeechText.segments(in: text)
        XCTAssertEqual(segments.map(\.text).joined().count, 470)
        XCTAssertTrue(segments.allSatisfy { $0.text.utf16.count <= SpeechText.maxSegmentLength })
        XCTAssertEqual(segments.map(\.utf16Offset), [0, 200, 400])
    }

    func testBlankInputAndParagraphBreaks() {
        XCTAssertTrue(SpeechText.segments(in: "").isEmpty)
        XCTAssertTrue(SpeechText.segments(in: "  \n \t ").isEmpty)
        XCTAssertEqual(SpeechText.segments(in: "甲。\n\n乙。").map(\.text), ["甲。", "乙。"])
        XCTAssertEqual(SpeechText.segments(in: " 空  格  合并 。").map(\.text), ["空 格 合并。"])
    }

    func testStartIndexUsesProgressionOverChapterLength() {
        let text = "第一句。第二句。第三句。第四句。"
        let segments = SpeechText.segments(in: text)
        let length = text.utf16.count
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: length, progression: 0), 0)
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: length, progression: 0.5), 2)
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: length, progression: 1), 3)
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: length, progression: -1), 0)
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: length, progression: 2), 3)
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: length, progression: .nan), 0)
        XCTAssertEqual(SpeechText.startIndex(in: [], chapterUTF16Length: length, progression: 0.5), 0)
        XCTAssertEqual(SpeechText.startIndex(in: segments, chapterUTF16Length: 0, progression: 0.5), 0)
    }
}

extension SpeechTextTests {
    func testCollapsedWhitespaceRetainsSourceCoordinates() {
        let source = "  甲   乙  。\n😀后句！"
        let segments = SpeechText.segments(in: source)
        XCTAssertEqual(segments[0].text, "甲 乙。")
        XCTAssertEqual(segments[0].sourceUTF16Offsets, [2, 3, 6, 9])
        XCTAssertEqual(segments[0].sourceRange, 2..<10)
        XCTAssertEqual(segments[0].sourceOffset(forSpokenOffset: 2), 6)
        XCTAssertEqual(segments[1].sourceOffset(forSpokenOffset: 2), 13)
        XCTAssertEqual(segments[1].sourceRange, 11..<16)
    }

    func testDisplayChunksMapRepeatedTextInOrderAndClipHighlights() {
        let ranges = SpeechText.sourceRanges(of: ["相同", "相同", "缺失"], in: "相同\n\n相同")
        XCTAssertEqual(ranges[0], 0..<2)
        XCTAssertEqual(ranges[1], 4..<6)
        XCTAssertNil(ranges[2])
        XCTAssertEqual(SpeechText.localRange(1..<5, in: 4..<6), 0..<1)
        XCTAssertNil(SpeechText.localRange(1..<3, in: 4..<6))
    }
}

extension SpeechTextTests {
    func testVisibleDOMOffsetRequiresMatchingQuoteAndPreservesOriginalWhitespace() {
        let source = "甲 乙。\n  😀后半句。甲乙。"
        XCTAssertEqual(SpeechText.sourceOffset(visibleNonWhitespaceOffset: 3, quote: "😀后半句。", in: source), 7)
        XCTAssertNil(SpeechText.sourceOffset(visibleNonWhitespaceOffset: 0, quote: "后半句", in: source))
        XCTAssertNil(SpeechText.sourceOffset(visibleNonWhitespaceOffset: -1, quote: "甲", in: source))
    }
    func testVisiblePageStartSplitsLongSentenceWithoutLosingPrefix() {
        let text = "页面前半后半句。"
        let split = SpeechText.splitAtVisibleOffset(SpeechText.segments(in: text), offset: 4)
        XCTAssertEqual(split.map(\.text), ["页面前半", "后半句。"])
        XCTAssertEqual(split[1].utf16Offset, 4)
        XCTAssertEqual(split.map(\.text).joined(), text)
        let chunks = CloudSpeechText.chunks(in: text, startingAt: 4.1 / Double(text.utf16.count), visibleOffset: 4)
        let index = CloudSpeechText.startIndex(in: chunks, length: text.utf16.count, progression: 4.1 / Double(text.utf16.count))
        XCTAssertTrue(chunks[index].text.hasPrefix("后半句。"))
    }
    func testVisibleSplitNeverCutsSurrogatePair() {
        let split = SpeechText.splitAtVisibleOffset(SpeechText.segments(in: "甲😀乙。"), offset: 2)
        XCTAssertEqual(split.map(\.text), ["甲", "😀乙。"])
    }
}
