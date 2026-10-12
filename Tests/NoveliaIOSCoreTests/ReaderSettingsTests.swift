import XCTest
@testable import NoveliaIOSCore

final class ReaderSettingsTests: XCTestCase {
    @MainActor
    func testExistingFlowPreferenceWinsAndReadsWithoutMigrationWrites() throws {
        let suite = "ReaderSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(25.0, forKey: "readerFontSize")
        let original = Data(#"{"fontSize":21,"leftMargin":27,"futureOption":"keep"}"#.utf8)
        defaults.set(original, forKey: "epubPrototype.readerStyle.v1")
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.fontSize, 25)
        XCTAssertEqual(defaults.data(forKey: ReaderSettings.epubStyleKey), original)
        settings.fontSize = 28
        let style = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: ReaderSettings.epubStyleKey))) as? [String: Any])
        XCTAssertEqual(style["fontSize"] as? Double, 28)
        XCTAssertEqual(style["leftMargin"] as? Int, 27)
        XCTAssertEqual(style["futureOption"] as? String, "keep")
        XCTAssertEqual(defaults.double(forKey: "readerFontSize"), 28)
        XCTAssertEqual(ReaderSettings(defaults: defaults).fontSize, 28)
    }

    @MainActor
    func testEPUBFallbackAndInvalidValues() throws {
        let suite = "ReaderSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"fontSize":23}"#.utf8), forKey: ReaderSettings.epubStyleKey)
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.fontSize, 23)
        settings.fontSize = 100
        XCTAssertEqual(settings.fontSize, 36)
        settings.adjustFontSize(by: -100)
        XCTAssertEqual(settings.fontSize, 12)
        settings.fontSize = .nan
        XCTAssertEqual(settings.fontSize, 20)
        settings.appearanceRaw = "unexpected"
        XCTAssertEqual(settings.appearanceRaw, "system")
    }

    @MainActor
    func testAppearanceAndProgressUseExistingKeys() throws {
        let suite = "ReaderSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertFalse(settings.isDark(systemIsDark: false))
        XCTAssertTrue(settings.isDark(systemIsDark: true))
        settings.appearanceRaw = "light"
        XCTAssertFalse(settings.isDark(systemIsDark: true))
        settings.appearanceRaw = "dark"
        XCTAssertTrue(settings.isDark(systemIsDark: false))
        XCTAssertEqual(defaults.string(forKey: "readerAppearance"), "dark")
        settings.progress.save(chapterIndex: 6, updatedAt: .distantPast, novelID: "example")
        XCTAssertEqual(defaults.integer(forKey: "progress.example"), 6)
    }

    @MainActor
    func testPagedTextReadingDefaultsOffAndPersists() throws {
        let suite = "ReaderSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertFalse(settings.pagedTextReading)
        XCTAssertNil(defaults.object(forKey: SettingsKey.readerPagedText), "reading must not write")
        settings.pagedTextReading = true
        XCTAssertTrue(ReaderSettings(defaults: defaults).pagedTextReading)
    }
}
