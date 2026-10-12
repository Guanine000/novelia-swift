import Foundation
import XCTest
@testable import NoveliaIOSCore

/// Encoding detection and chapter splitting for imported TXT files.
final class TXTChapterParserTests: XCTestCase {
    private func encoded(_ text: String, _ charset: String) -> Data {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return text.data(using: encoding)!
    }

    func testDecodesCommonEncodings() {
        let text = "第一章 開始\n這是正文。"
        XCTAssertEqual(TXTTextDecoder.decode(data: Data(text.utf8)), text, "UTF-8")
        XCTAssertEqual(TXTTextDecoder.decode(data: Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), text, "UTF-8 BOM")
        XCTAssertEqual(TXTTextDecoder.decode(data: Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!), text, "UTF-16 LE BOM")
        XCTAssertEqual(TXTTextDecoder.decode(data: Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!), text, "UTF-16 BE BOM")
        let simplified = "第一章 开始\n这是正文。"
        XCTAssertEqual(TXTTextDecoder.decode(data: encoded(simplified, "GB18030")), simplified, "GB18030")
    }

    func testSplitsNumberedChaptersWithPreface() {
        let text = """
        作品简介写在这里。

        第一章 出发
        第一章的正文。
        第二章 相遇
        第二章的正文。
        第三章 告别
        第三章的正文。
        """
        let chapters = TXTChapterParser.parse(text)
        XCTAssertEqual(chapters.map(\.title), ["前言", "第一章 出发", "第二章 相遇", "第三章 告别"])
        guard chapters.count == 4 else { return }
        XCTAssertEqual(chapters[1].body, "第一章的正文。")
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2, 3])
    }

    func testVolumesAndSpecialTitles() {
        // Bodies span several lines: adjacent heading lines read as a table of contents.
        let body = (1...4).map { "这是第\($0)段正文，写得足够长以免被当成目录。" }.joined(separator: "\n")
        let text = ["第一卷 春", "序章", body, "第一章 一", body, "第二章 二", body,
                    "第二卷 夏", "第三章 三", body, "后记", body].joined(separator: "\n")
        let chapters = TXTChapterParser.parse(text)
        XCTAssertEqual(chapters.map(\.title), ["序章", "第一章 一", "第二章 二", "第三章 三", "后记"])
        guard chapters.count == 5 else { return }
        XCTAssertEqual(chapters[1].volumeTitle, "第一卷 春")
        XCTAssertEqual(chapters[3].volumeTitle, "第二卷 夏")
        XCTAssertEqual(chapters[1].body, body)
    }

    func testFewHeadingsFallBackToFullText() {
        let text = "第一章 唯一\n正文只有一章。"
        let chapters = TXTChapterParser.parse(text)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "全文")
        XCTAssertEqual(chapters[0].body, text)
    }

    func testEnglishChapters() {
        let text = (1...3).map { "Chapter \($0): Part \($0)\nBody \($0)." }.joined(separator: "\n")
        XCTAssertEqual(TXTChapterParser.parse(text).map(\.title), ["Chapter 1: Part 1", "Chapter 2: Part 2", "Chapter 3: Part 3"])
    }

    func testDisabledRuleIsIgnored() {
        let text = (1...3).map { "Chapter \($0)\nBody \($0)." }.joined(separator: "\n")
        let rules = TXTChapterRuleConfiguration(
            enabledBuiltInIDs: Set(TXTChapterRule.builtInDefaults.map(\.id)).subtracting(["english-chapter"]),
            enabledCustomRules: [])
        XCTAssertEqual(TXTChapterParser.parse(text, rules: rules).map(\.title), ["全文"])
    }

    func testCustomRule() {
        let rule = TXTChapterRule(id: "custom-star", name: "星号", pattern: #"^★.+$"#, explanation: "", isEnabled: true, isBuiltIn: false)
        let text = "★甲\n一\n★乙\n二\n★丙\n三"
        let rules = TXTChapterRuleConfiguration(enabledBuiltInIDs: [], enabledCustomRules: [rule])
        XCTAssertEqual(TXTChapterParser.parse(text, rules: rules).map(\.title), ["★甲", "★乙", "★丙"])
    }
}
