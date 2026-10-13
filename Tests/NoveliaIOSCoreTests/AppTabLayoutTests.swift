import XCTest
@testable import NoveliaIOSCore

/// 自定义底栏：顺序读取与启动页面。
final class AppTabLayoutTests: XCTestCase {
    func testOrderNormalizesStoredValue() {
        XCTAssertEqual(AppTabLayout.order(from: nil), AppTab.allCases)
        XCTAssertEqual(AppTabLayout.order(from: ""), AppTab.allCases)
        XCTAssertEqual(AppTabLayout.order(from: "me,library,community,discover"), [.me, .library, .community, .discover])
        XCTAssertEqual(AppTabLayout.order(from: "community,unknown,community"), [.community, .library, .discover, .me],
                       "unknown and duplicate values dropped, missing tabs appended")
        XCTAssertEqual(AppTabLayout.storedValue(for: [.discover, .discover]), "discover,library,community,me")
    }

    func testLaunchTab() {
        XCTAssertEqual(AppLaunchTab(rawValue: nil), .fixed(.library))
        XCTAssertEqual(AppLaunchTab(rawValue: "bogus"), .fixed(.library))
        XCTAssertEqual(AppLaunchTab(rawValue: "community"), .fixed(.community))
        XCTAssertEqual(AppLaunchTab(rawValue: "last"), .lastUsed)
        XCTAssertEqual(AppLaunchTab.lastUsed.rawValue, "last")

        let order: [AppTab] = [.discover, .library, .community, .me]
        XCTAssertEqual(AppTabLayout.initialTab(launch: .fixed(.me), lastSelected: "discover", order: order), .me)
        XCTAssertEqual(AppTabLayout.initialTab(launch: .lastUsed, lastSelected: "community", order: order), .community)
        XCTAssertEqual(AppTabLayout.initialTab(launch: .lastUsed, lastSelected: nil, order: order), .discover)
        XCTAssertEqual(AppTabLayout.initialTab(launch: .lastUsed, lastSelected: "gone", order: order), .discover)
    }
}
