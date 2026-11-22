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

        let readingOrder = [Link(href: "Section0005.xhtml", mediaType: .xhtml)]
        var links = [Link(href: "Section0005.xhtml", mediaType: .xhtml, title: "file")]
        links += (0..<10).map { Link(href: "Section0005.xhtml#id\($0)", mediaType: .xhtml, title: "id\($0)") }
        let index = ReadiumNavigationIndex(readingOrder: readingOrder, tableOfContents: links)
        var expectedFragments: [String?] = [nil]
        expectedFragments.append(contentsOf: (0..<10).map { "id\($0)" })
        XCTAssertEqual(index.fragments(inResource: 0), expectedFragments)
        XCTAssertTrue(index.needsLayoutMeasurement(resource: 0))
        XCTAssertEqual(index.fragmentIDs(inResource: 0), (0..<10).map { "id\($0)" })
        XCTAssertEqual(index.highlightIndex(resource: 0, viewportProgression: 0.99, measurements: nil), 0,
                       "几何尚未量到时回退到该文件第一项")

        var layout: [String: Double] = [:]
        for number in 0..<10 { layout["id\(number)"] = Double(number + 1) / 10 }
        XCTAssertEqual(index.highlightIndex(resource: 0, viewportProgression: layout["id0"], measurements: layout), 1)
        XCTAssertEqual(index.highlightIndex(resource: 0, viewportProgression: layout["id9"], measurements: layout), 10)
        XCTAssertEqual(index.highlightIndex(resource: 0, viewportProgression: (layout["id0"] ?? 0) - 0.01, measurements: layout), 0,
                       "页首还没到 #id0 时不高亮它；右栏里才出现的下一节同样要等页首到达")
        var withoutLast = layout
        withoutLast["id9"] = nil
        XCTAssertEqual(index.highlightIndex(resource: 0, viewportProgression: 0.99, measurements: withoutLast), 9,
                       "找不到的 id 跳过，不能因此改成最后一项")
    }

    func testReadiumGeometrySnapshotAndStaleMeasureAreDistinct() throws {
        let json = #"{"href":"Section0005.xhtml","viewport":0.42,"found":{"id0":0.1,"id9":0.9},"missing":["gone"]}"#
        let snapshot = try XCTUnwrap(ReadiumTOCGeometryScript.parse(jsonString: json))
        XCTAssertEqual(snapshot.href, "Section0005.xhtml")
        XCTAssertEqual(snapshot.viewportProgression, 0.42)
        XCTAssertEqual(snapshot.found["id0"], 0.1)
        XCTAssertEqual(snapshot.found["id9"], 0.9)
        XCTAssertNil(snapshot.found["gone"])
        XCTAssertNil(ReadiumTOCGeometryScript.parse(jsonString: #"{"href":"Section0005.xhtml","viewport":null,"found":{}}"#))
        XCTAssertNil(ReadiumTOCGeometryScript.parse(jsonString: #"{"href":"","viewport":0.1,"found":{}}"#))

        let script = try XCTUnwrap(ReadiumTOCGeometryScript.source(fragmentIDs: ["id0", "id9"]))
        XCTAssertTrue(script.contains(#"["id0","id9"]"#))
        XCTAssertTrue(script.contains("readium-scroll-on"))
        XCTAssertTrue(script.contains("vertical-rl"))
        XCTAssertFalse(script.contains("innerHTML"))

        let current = ReadiumTOCMeasureToken(generation: 3, resource: 1)
        XCTAssertTrue(ReadiumTOCMeasureGate.shouldApply(requested: current, latest: current, queriedRealNavigator: true))
        XCTAssertFalse(ReadiumTOCMeasureGate.shouldApply(
            requested: ReadiumTOCMeasureToken(generation: 2, resource: 1), latest: current, queriedRealNavigator: true))
        XCTAssertFalse(ReadiumTOCMeasureGate.shouldApply(
            requested: ReadiumTOCMeasureToken(generation: 3, resource: 0), latest: current, queriedRealNavigator: true))
        XCTAssertFalse(ReadiumTOCMeasureGate.shouldApply(requested: current, latest: current, queriedRealNavigator: false),
                       "仿真翻页快照上的测量不能写回")
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
}
