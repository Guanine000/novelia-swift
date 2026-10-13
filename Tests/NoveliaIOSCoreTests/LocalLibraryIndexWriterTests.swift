import Foundation
import XCTest
@testable import NoveliaIOSCore

final class LocalLibraryIndexWriterTests: XCTestCase {
    private struct ThreadCheckedSnapshot: Encodable, Sendable {
        let revision: Int
        func encode(to encoder: Encoder) throws {
            // Encoding itself, not just the file write, must be off the main thread.
            if Thread.isMainThread { throw CocoaError(.coderInvalidValue) }
            var container = encoder.singleValueContainer()
            try container.encode(revision)
        }
    }

    @MainActor
    func testEncodingAndWritingLeaveMainThread() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await LocalLibraryIndexWriter().write(ThreadCheckedSnapshot(revision: 7), to: url)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: Data(contentsOf: url)), 7)
    }

    func testNewerSynchronousEditWinsAfterBackgroundRefresh() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = LocalLibraryIndexWriter()
        try await writer.write(["old"], to: url)
        try writer.writeSync(["new", "edited"], to: url)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)), ["new", "edited"])
    }

    func testWriteFailurePropagatesWithoutReplacingExistingIndex() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = parent.appendingPathComponent("library.json")
        do {
            try await LocalLibraryIndexWriter().write(["book"], to: url)
            XCTFail("Missing parent must cause a write failure")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
