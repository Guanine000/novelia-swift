import Foundation
import XCTest
@testable import NoveliaIOSCore

final class BookTextSearchTests: XCTestCase {
    func testPlainTextMatchesTheProgressLengthRules() {
        let html = "<html><head><title>T</title><style>p{}</style></head><body>\n  <p>Ａｂｃ &amp; 魔法</p>\n<!-- note --><p>第二段&#x4E00;</p></body></html>"
        let text = BookTextSearch.plainText(html: html)
        XCTAssertEqual(text, "Ａｂｃ & 魔法第二段一")
        XCTAssertEqual(text.utf16.count, EPUBChapterProgress.textLength(html: html), "offsets use the same measure as reading positions")
    }

    func testMatchesAreCaseAndWidthInsensitiveWithContext() {
        let text = String(repeating: "前", count: 30) + "ABC" + String(repeating: "后", count: 50) + "abc"
        let hits = BookTextSearch.matches(in: text, query: " ａｂｃ ", chapterIndex: 3)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].chapterIndex, 3)
        XCTAssertEqual(hits[0].match, "ABC")
        XCTAssertEqual(hits[0].before.count, 20)
        XCTAssertEqual(hits[0].after.count, 40)
        XCTAssertEqual(hits[0].progression, 30.0 / Double(text.utf16.count), accuracy: 1e-9)
        XCTAssertTrue(BookTextSearch.matches(in: text, query: "  ", chapterIndex: 0).isEmpty)
        XCTAssertEqual(BookTextSearch.matches(in: text, query: "abc", chapterIndex: 0, limit: 1).count, 1)
    }

    func testSearchAcrossChaptersSkipsFailuresAndHonorsTheLimit() async {
        let chapters = ["没有", "这里有魔法", "魔法和魔法"]
        var progress: [Int] = []
        let hits = await BookTextSearch.search(query: "魔法", chapterCount: 4, chapterText: { index in
            guard chapters.indices.contains(index) else { throw CancellationError() }
            return chapters[index]
        }, onChapter: { progress.append($0) })
        XCTAssertEqual(hits.map(\.chapterIndex), [1, 2, 2])
        XCTAssertEqual(progress, [1, 2, 3, 4], "an unreadable chapter is skipped")
        let limited = await BookTextSearch.search(query: "魔法", chapterCount: 3, limit: 2, chapterText: { chapters[$0] })
        XCTAssertEqual(limited.count, 2)
    }
}
