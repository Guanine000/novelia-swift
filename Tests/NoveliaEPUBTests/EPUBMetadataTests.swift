import UIKit
import XCTest
@testable import NoveliaEPUB

/// Library metadata read on import. Expected values were cross-checked against the
/// Readium parser this replaced (swift-toolkit 3.11.0) on the same fixtures.
final class EPUBMetadataTests: XCTestCase {
    struct Expected {
        let title: String
        let authors: [String]
        let description: String?
        let coverPixels: CGSize?
    }

    static let expectations: [String: Expected] = [
        "epub2_meta_cover": Expected(title: "文庫 & 測試", authors: ["作者甲", "作者丙"],
                                     description: "<p>簡介 第一行</p>", coverPixels: CGSize(width: 214, height: 320)),
        "epub3_refines": Expected(title: "Main Title", authors: ["Author One", "Odd Role"],
                                  description: "<b>Bold</b> desc", coverPixels: CGSize(width: 100, height: 120)),
        "root_opf_nocover": Expected(title: "Spaced   Title", authors: ["Solo"], description: nil, coverPixels: nil),
        "small_cover": Expected(title: "Small", authors: [], description: "Line one\n line two",
                                coverPixels: CGSize(width: 80, height: 60)),
        "wide_cover": Expected(title: "Wide", authors: [], description: nil, coverPixels: CGSize(width: 240, height: 72)),
    ]

    static func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "epub", subdirectory: "Fixtures"))
    }

    func testMetadataMatchesExpectations() async throws {
        for (name, expected) in Self.expectations {
            let metadata = await EPUBContainer.metadata(
                fileURL: try Self.fixture(name), coverMaxSize: CGSize(width: 240, height: 320))
            let value = try XCTUnwrap(metadata, name)
            XCTAssertEqual(value.title, expected.title, name)
            XCTAssertEqual(value.authors, expected.authors, name)
            XCTAssertEqual(value.description, expected.description, name)
            let pixels = value.cover.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) }
            XCTAssertEqual(pixels, expected.coverPixels, name)
        }
    }

    /// The reader's title bar and the library list use the same title rule.
    func testReaderTitleMatchesLibraryTitle() async throws {
        for name in Self.expectations.keys {
            let url = try Self.fixture(name)
            let container = try await EPUBContainer.open(fileURL: url)
            let metadata = await EPUBContainer.metadata(fileURL: url, coverMaxSize: CGSize(width: 240, height: 320))
            XCTAssertEqual(container.bookTitle, metadata?.title, name)
        }
    }

    func testNonEPUBReturnsNil() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-epub-\(UUID()).epub")
        try Data("plain text".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = await EPUBContainer.metadata(fileURL: url, coverMaxSize: CGSize(width: 240, height: 320))
        XCTAssertNil(metadata)
    }
}
