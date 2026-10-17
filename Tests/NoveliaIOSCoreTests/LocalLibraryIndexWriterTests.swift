import Foundation
import XCTest
@testable import NoveliaIOSCore

final class LocalLibraryIndexWriterTests: XCTestCase {
    private struct ThreadCheckedSnapshot: Encodable, Sendable {
        let revision: Int
        func encode(to encoder: Encoder) throws {
            // 编码本身也必须在主线程之外执行，而不只是文件写入。
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

    @MainActor
    func testBackgroundCopyKeepsSourceAndDoesNotOverwriteDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.epub")
        let destination = directory.appendingPathComponent("copied.epub")
        let content = Data(repeating: 42, count: 1024 * 1024)
        try content.write(to: source)
        let writer = LocalLibraryFileCopier()
        try await writer.copy(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), content)
        XCTAssertEqual(try Data(contentsOf: source), content)
        do {
            try await writer.copy(from: source, to: destination)
            XCTFail("Existing destinations must not be overwritten")
        } catch { XCTAssertEqual(try Data(contentsOf: destination), content) }
        let missing = directory.appendingPathComponent("missing")
        let failed = directory.appendingPathComponent("failed.epub")
        do {
            try await writer.copy(from: missing, to: failed)
            XCTFail("Missing source must fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".copy-") })
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
