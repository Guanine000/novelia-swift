import XCTest
import ReadiumZIPFoundation
@testable import NoveliaEPUB

/// 合成书籍验证 EPUB 按 spine 统计字数：缺失章节计 0，不影响其他章节。
final class EPUBWordCountTests: XCTestCase {
    func testCountsEachSpineItemAndTreatsMissingChaptersAsZero() async throws {
        let opf = """
        <package><metadata><title>字数测试</title></metadata><manifest>
        <item id="a" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
        <item id="b" href="Text/missing.xhtml" media-type="application/xhtml+xml"/>
        <item id="c" href="Text/three.xhtml" media-type="application/xhtml+xml"/>
        </manifest><spine><itemref idref="a"/><itemref idref="b"/><itemref idref="c"/></spine></package>
        """
        let url = try await archive([
            ("META-INF/container.xml", "<container><rootfiles><rootfile full-path='Book/content.opf'/></rootfiles></container>"),
            ("Book/content.opf", opf),
            ("Book/Text/one.xhtml", "<html><head><title>不计</title></head><body><h1>序章</h1><p>你好，world。</p></body></html>"),
            ("Book/Text/three.xhtml", "<html><body><p><ruby>魔<rt>ま</rt></ruby>法&amp;Magic</p></body></html>"),
        ])
        let counts = try await EPUBContainer.wordCounts(fileURL: url)
        // 序章(2) + 你好，(3) + world + 。 ；魔 + 法 + & Magic（标签与实体之间没有空白，合成一个词）
        XCTAssertEqual(counts.chapters, [7, 0, 3])
        XCTAssertEqual(counts.total, 10)
    }

    private func archive(_ entries: [(String, String)]) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        let zip = try await Archive(url: url, accessMode: .create)
        for (path, text) in entries {
            let temporary = directory.appendingPathComponent("entry")
            try Data(text.utf8).write(to: temporary)
            try await zip.addEntry(with: path, fileURL: temporary, compressionMethod: .none)
        }
        return url
    }
}
