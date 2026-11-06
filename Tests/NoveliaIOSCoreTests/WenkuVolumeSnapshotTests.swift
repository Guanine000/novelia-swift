import XCTest
@testable import NoveliaIOSCore

final class WenkuVolumeSnapshotTests: XCTestCase {
    private func detail(_ ids: [String], translated: [String] = [], id: String = "work", count: Int = 1) throws -> WenkuNovelDetail {
        let volumes = try ids.map { volume in
            try JSONDecoder().decode(WenkuVolumeAvailability.self, from: JSONSerialization.data(withJSONObject:
                ["volumeId": volume, "total": count, "baidu": 0, "youdao": 0, "gpt": count, "sakura": 0]))
        }
        return .init(id: id, title: id, titleZh: "", cover: nil, authors: [], artists: [], keywords: [],
            publisher: nil, imprint: nil, latestPublishAt: nil, level: "0", introduction: "", webIds: [],
            volumes: [], glossary: [:], visited: 0, favored: nil, volumeZh: translated, volumeJp: volumes)
    }
    func testFirstCheckAndNewIDsIgnoreOrderingAndRemovals() throws {
        var history = WenkuVolumeHistory()
        let first = history.record(try detail(["one", "two"]), account: "a")
        XCTAssertEqual(first.status, .initial); XCTAssertTrue(first.newVolumeIDs.isEmpty)
        let second = history.record(try detail(["three", "two", "one"]), account: "a")
        XCTAssertEqual(second.status, .compared); XCTAssertEqual(second.newVolumeIDs, ["three"])
        XCTAssertTrue(history.record(try detail(["two", "three"]), account: "a").newVolumeIDs.isEmpty)
    }
    func testHistoryRoundTripIsolatesAccountsAndWorks() throws {
        var history = WenkuVolumeHistory()
        _ = history.record(try detail(["one"]), account: "a")
        XCTAssertEqual(history.record(try detail(["one", "two"]), account: "b").status, .initial)
        XCTAssertEqual(history.record(try detail(["one", "two"], id: "other"), account: "a").status, .initial)
        var reopened = try JSONDecoder().decode(WenkuVolumeHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(reopened.record(try detail(["one", "two"]), account: "a").newVolumeIDs, ["two"])
    }
    func testEmptyResponseDoesNotDestroyPreviousBaseline() throws {
        var history = WenkuVolumeHistory()
        _ = history.record(try detail(["one"]), account: "a", now: Date(timeIntervalSince1970: 10))
        let empty = history.record(try detail([]), account: "a")
        XCTAssertEqual(empty.status, .unavailable); XCTAssertNil(empty.snapshot)
        XCTAssertEqual(empty.previousCheck, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(history.record(try detail(["one", "two"]), account: "a").newVolumeIDs, ["two"])
    }
    func testExistingOriginalCatalogIgnoresTranslatedAndChapterCountChanges() throws {
        var history = WenkuVolumeHistory()
        _ = history.record(try detail(["one"], translated: ["zh-one"], count: 1), account: "a")
        let next = history.record(try detail(["one"], translated: ["zh-one", "zh-two"], count: 99), account: "a")
        XCTAssertEqual(next.snapshot?.catalog, .original); XCTAssertTrue(next.newVolumeIDs.isEmpty)
    }
    func testSwitchingCatalogTypeStartsANewBaseline() throws {
        var history = WenkuVolumeHistory()
        _ = history.record(try detail([], translated: ["zh-one"]), account: "a")
        let changed = history.record(try detail(["jp-one"]), account: "a")
        XCTAssertEqual(changed.status, .catalogChanged); XCTAssertTrue(changed.newVolumeIDs.isEmpty)
        XCTAssertEqual(history.record(try detail(["jp-one", "jp-two"]), account: "a").newVolumeIDs, ["jp-two"])
    }
}
