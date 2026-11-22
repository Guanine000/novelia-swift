import XCTest
import ReadiumShared
@testable import NoveliaEPUB

/// 一个 spine 文件里有文件本身和 #id0…#id9。高亮必须按章内位置取对应项，
/// 不能因为它们共用一个文件就总是最后一项或总是第一项。
final class EPUBTOCAnchorTests: XCTestCase {
    func testSameFileAnchorsHighlightByInFilePosition() throws {
        let entries = tocEntries()
        let offsets = anchorOffsets()
        XCTAssertEqual(entries.map(\.fragment), [nil] + (0..<10).map { "id\($0)" })
        XCTAssertEqual(entries[1].fragment, "id0")
        XCTAssertEqual(entries[10].fragment, "id9")

        let atStart = EPUBTOCHighlight.index(entries: entries, spineIndex: 0,
                                             pageSourceOffset: 0, anchorOffsets: offsets)
        let atID0 = EPUBTOCHighlight.index(entries: entries, spineIndex: 0,
                                           pageSourceOffset: offsets["id0"], anchorOffsets: offsets)
        let atID9 = EPUBTOCHighlight.index(entries: entries, spineIndex: 0,
                                           pageSourceOffset: offsets["id9"], anchorOffsets: offsets)
        XCTAssertEqual(atStart, 0, "文件开头高亮文件项")
        XCTAssertEqual(atID0, 1, "#id0 的位置高亮 #id0")
        XCTAssertEqual(entries[try XCTUnwrap(atID0)].fragment, "id0")
        XCTAssertEqual(atID9, 10, "#id9 的位置高亮 #id9")
        XCTAssertEqual(entries[try XCTUnwrap(atID9)].fragment, "id9")
        XCTAssertNotEqual(atID0, atID9)

        let between = EPUBTOCHighlight.index(entries: entries, spineIndex: 0,
                                             pageSourceOffset: offsets["id0"]! + 1, anchorOffsets: offsets)
        XCTAssertEqual(between, 1, "刚过 #id0、尚未到 #id1 时仍是 #id0")

        let unknown = EPUBTOCHighlight.index(entries: entries, spineIndex: 0,
                                             pageSourceOffset: nil, anchorOffsets: nil)
        XCTAssertEqual(unknown, 0, "偏移未知时回退到该文件第一项，而不是最后一项")

        let nextFile = EPUBTOCHighlight.index(entries: entries, spineIndex: 1,
                                              pageSourceOffset: 0, anchorOffsets: [:])
        XCTAssertEqual(nextFile, 10, "进入后一个没有目录项的文件时，高亮前一文件已经开始的最后一节")

        let html = chapterHTML()
        var progressions: [Int: Double] = [0: try XCTUnwrap(ReadiumTOCFragmentProgression.progression(fragment: nil, html: html))]
        for index in 0..<10 {
            let value = try XCTUnwrap(ReadiumTOCFragmentProgression.progression(fragment: "id\(index)", html: html))
            if index > 0 { XCTAssertGreaterThan(value, progressions[index]!) }
            progressions[index + 1] = value
        }
        let readingOrder = [Link(href: "Section0005.xhtml", mediaType: .xhtml)]
        var links = [Link(href: "Section0005.xhtml", mediaType: .xhtml, title: "file")]
        links += (0..<10).map { Link(href: "Section0005.xhtml#id\($0)", mediaType: .xhtml, title: "id\($0)") }
        let pending = ReadiumNavigationIndex(readingOrder: readingOrder, tableOfContents: links)
        var expectedFragments: [String?] = [nil]
        expectedFragments.append(contentsOf: (0..<10).map { "id\($0)" })
        XCTAssertEqual(pending.fragments(inResource: 0), expectedFragments)
        let href = readingOrder[0].url()
        XCTAssertEqual(pending.tocIndex(for: Locator(href: href, mediaType: .xhtml, locations: .init(progression: 0.99))), 0,
                       "progression 尚未就绪时回退到该文件第一项")

        let index = pending.applying(progressions: progressions)
        let atReadium0 = index.tocIndex(for: Locator(href: href, mediaType: .xhtml,
                                                     locations: .init(progression: progressions[1])))
        let atReadium9 = index.tocIndex(for: Locator(href: href, mediaType: .xhtml,
                                                     locations: .init(progression: progressions[10])))
        XCTAssertEqual(atReadium0, 1)
        XCTAssertEqual(atReadium9, 10)
        XCTAssertNotEqual(atReadium0, atReadium9)
    }

    func testSpineMatchKeepsFragmentSeparateFromFile() {
        let match = EPUBContainer.spineMatch(
            href: "../Section0005.xhtml#sigil_toc_id_1",
            baseDirectory: "Text/OEBPS/",
            spineHrefs: ["Text/Section0005.xhtml", "Text/Section0006.xhtml"])
        XCTAssertEqual(match.index, 0)
        XCTAssertEqual(match.fragment, "sigil_toc_id_1")
        let encoded = EPUBContainer.spineMatch(
            href: "Section0005.xhtml#sigil_toc_id_9",
            baseDirectory: "Text/",
            spineHrefs: ["Text/Section0005.xhtml"])
        XCTAssertEqual(encoded.index, 0)
        XCTAssertEqual(encoded.fragment, "sigil_toc_id_9")
        XCTAssertNil(EPUBContainer.tocFragment(in: "Section0005.xhtml"))
        XCTAssertEqual(EPUBContainer.tocFragment(in: "Section0005.xhtml#id%2F0"), "id/0")
    }

    private func tocEntries() -> [EPUBTOCEntry] {
        var entries = [EPUBTOCEntry(title: "file", spineIndex: 0)]
        for index in 0..<10 {
            entries.append(EPUBTOCEntry(title: "id\(index)", spineIndex: 0, fragment: "id\(index)"))
        }
        return entries
    }

    private func anchorOffsets() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: (0..<10).map { ("id\($0)", ($0 + 1) * 1000) })
    }

    private func chapterHTML() -> String {
        var body = "<h1 id=\"file\">文件</h1><p>\(String(repeating: "甲", count: 40))</p>"
        for index in 0..<10 {
            body += "<h2 id=\"id\(index)\">第\(index)节</h2><p>\(String(repeating: "乙", count: 80))</p>"
        }
        return "<html><body>\(body)</body></html>"
    }
}
