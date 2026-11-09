#!/usr/bin/env python3
"""复用独立验证App的UI夹具，检查原生卷页；不操作生产App或用户书库。"""
from pathlib import Path
import sys
base = Path(__file__).with_name('test_api_architecture_ui.py')
source = base.read_text()
methods = r'''
 func openNativeCurlTXT() -> XCUIApplication {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: bundle)
  app.launchArguments = ["-architectureValidation", "-resetArchitectureValidation", "-architectureTXT", "-readerPagedText", "YES"]
  app.launch()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].waitForExistence(timeout: 20))
  let book = app.staticTexts["架构验证TXT"].firstMatch
  XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
  XCTAssertTrue(app.buttons["阅读菜单"].waitForExistence(timeout: 30))
  readerAction(app, "分页阅读").tap()
  XCTAssertTrue(app.buttons["阅读菜单"].waitForExistence(timeout: 30))
  readerAction(app, "阅读设置").tap()
  let picker = app.descendants(matching: .any).matching(identifier: "reader-native-page-turn").firstMatch
  reveal(picker, app: app); picker.tap(); app.buttons["仿真翻页"].firstMatch.tap()
  app.buttons["关闭"].firstMatch.tap()
  XCTAssertTrue(app.buttons["阅读菜单"].waitForExistence(timeout: 10))
  return app
 }
 func nativePageLabel(_ app: XCUIApplication) -> String {
  let page = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*第 [0-9]+/[0-9]+ 页.*")).firstMatch
  XCTAssertTrue(page.waitForExistence(timeout: 10)); return page.label
 }
 func testNativeCurlTurnsAndRestoresPosition() {
  let app = openNativeCurlTXT(); defer { app.terminate() }
  let initial = nativePageLabel(app)
  for _ in 0..<10 { app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap() }
  XCTAssertNotEqual(nativePageLabel(app), initial)
  for _ in 0..<10 { app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap() }
  XCTAssertEqual(nativePageLabel(app), initial)
  app.swipeLeft(velocity: .slow); XCTAssertNotEqual(nativePageLabel(app), initial)
  app.swipeRight(velocity: .slow); XCTAssertEqual(nativePageLabel(app), initial)
  let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "原生仿真-正反跨章返回"; shot.lifetime = .keepAlways; add(shot)
  zeroExternalRequests(app)
 }
 func testNativeCurlChromeStyleSelectionAndRotation() {
  let app = openNativeCurlTXT(); defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
  let initial = nativePageLabel(app)
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
  XCTAssertFalse(app.buttons["阅读菜单"].exists)
  app.swipeLeft(velocity: .slow); XCTAssertNotEqual(nativePageLabel(app), initial)
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
  XCTAssertTrue(app.buttons["阅读菜单"].waitForExistence(timeout: 5))
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).press(forDuration: 0.7)
  let copy = app.buttons["拷贝"].firstMatch
  XCTAssertTrue(copy.waitForExistence(timeout: 5) || app.menuItems["拷贝"].firstMatch.exists)
  let selection = XCTAttachment(screenshot: app.screenshot()); selection.name = "原生仿真-选字"; selection.lifetime = .keepAlways; add(selection)
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
  XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
  app.swipeLeft(velocity: .slow)
  let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "原生仿真-横屏"; shot.lifetime = .keepAlways; add(shot)
  XCUIDevice.shared.orientation = .portrait; sleep(2)
  readerAction(app, "阅读设置").tap()
  let picker = app.descendants(matching: .any).matching(identifier: "reader-native-page-turn").firstMatch
  reveal(picker, app: app); picker.tap(); app.buttons["跟手平移"].firstMatch.tap()
  app.buttons["关闭"].firstMatch.tap(); app.swipeLeft(velocity: .slow)
  XCTAssertTrue(app.buttons["阅读菜单"].waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
'''
marker = ' func readerAction(_ app: XCUIApplication, _ title: String) -> XCUIElement {'
if source.count(marker) != 1:
    raise SystemExit('UI harness marker changed; update the native curl test adapter')
source = source.replace(marker, methods + marker)
if '--only-testing' not in sys.argv:
    sys.argv += ['--only-testing', 'TapTests/TapTests/testNativeCurlTurnsAndRestoresPosition',
                 '--only-testing', 'TapTests/TapTests/testNativeCurlChromeStyleSelectionAndRotation']
exec(compile(source, str(base), 'exec'), {'__name__': '__main__', '__file__': str(base)})
