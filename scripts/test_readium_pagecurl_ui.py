#!/usr/bin/env python3
"""使用独立三章编号EPUB验证Readium卷页；不读取生产书库或真实服务器。"""
from pathlib import Path
import sys
base = Path(__file__).with_name('test_api_architecture_ui.py')
source = base.read_text()
methods = r'''
     override func setUp() {
      super.setUp();XCUIDevice.shared.orientation = .portrait
     }
     override func tearDown() {
      XCUIDevice.shared.orientation = .portrait
      XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation").terminate()
      super.tearDown()
     }
     func openCurlBook() -> XCUIApplication {
      continueAfterFailure = false
      let app = XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES"]
      app.launch()
      let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap()
      waitForCurl(app)
      return app
     }
     func waitForCurl(_ app: XCUIApplication) {
      let state=app.staticTexts["readium-validation-curl-state"]
      XCTAssertTrue(state.waitForExistence(timeout:20))
      let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in state.label == "ready" },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:30),.completed, "Curl preparation must settle: \(state.label)\n\(app.debugDescription)")
      XCTAssertFalse(app.alerts["无法准备仿真翻页"].exists)
     }
     func curlVisible(_ app: XCUIApplication) -> [Int] {
      let probe=app.staticTexts["readium-validation-visible-paragraphs"]
      guard let data=probe.label.data(using:.utf8),let values=try? JSONSerialization.jsonObject(with:data) as? [Int] else{return []}
      return values.sorted()
     }
     func curlCounts(_ app: XCUIApplication) -> [Int] {
      app.staticTexts["readium-validation-curl-counts"].label.split(separator:",").compactMap { Int($0) }
     }
     func testReadiumCurlPreparationDoesNotSaveProgress() {
      let app=openCurlBook();defer{app.terminate()}
      let initial=curlVisible(app);XCTAssertEqual(initial.first,1)
      let counts=curlCounts(app);XCTAssertEqual(counts[1],0)
      sleep(2);XCTAssertEqual(curlVisible(app),initial);XCTAssertEqual(curlCounts(app),counts,"Stable page must not repeatedly prepare snapshots")
      let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Readium卷页-准备后原位置";shot.lifetime = .keepAlways;add(shot)
     }
     func testReadiumCurlCancelsPreparationOnRotation() {
      continueAfterFailure = false
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      defer{XCUIDevice.shared.orientation = .portrait;app.terminate()}
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES"]
      app.launch();let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap()
      let state=app.staticTexts["readium-validation-curl-state"]
      XCTAssertTrue(state.waitForExistence(timeout:20))
      let busy=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in state.label == "busy" },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[busy],timeout:20),.completed)
      XCUIDevice.shared.orientation = .landscapeLeft
      sleep(2);waitForCurl(app);XCTAssertEqual(curlVisible(app).first,1)
      XCUIDevice.shared.orientation = .portrait
      sleep(2);waitForCurl(app);XCTAssertEqual(curlVisible(app).first,1)
      XCTAssertEqual(curlCounts(app)[1],0)
      let counts=curlCounts(app);sleep(2);XCTAssertEqual(curlCounts(app),counts)
     }
     func testReadiumCurlCancellationAndRotation() {
      let app=openCurlBook();defer{XCUIDevice.shared.orientation = .portrait;app.terminate()}
      let initial=curlVisible(app), count=curlCounts(app)[1],cancelled=curlCounts(app)[2]
      let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5))
      let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.82,dy:0.5))
      start.press(forDuration:0.05,thenDragTo:end,withVelocity:.slow,thenHoldForDuration:0.5)
      waitForCurl(app);XCTAssertEqual(curlVisible(app),initial);XCTAssertEqual(curlCounts(app)[1],count);XCTAssertEqual(curlCounts(app)[2],cancelled+1)
      XCUIDevice.shared.orientation = .landscapeLeft
      sleep(2);waitForCurl(app);XCTAssertEqual(curlVisible(app).first,1)
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="Readium curl landscape safe area";shot.lifetime = .keepAlways;add(shot)
      XCUIDevice.shared.orientation = .portrait
      sleep(2);waitForCurl(app);XCTAssertEqual(curlVisible(app),initial)
     }
     func testReadiumCurlStyleToggleAndSelection() {
      let app=openCurlBook();defer{app.terminate()}
      for title in ["跟手平移","仿真翻页"] {
       let menu=app.buttons["阅读菜单"].firstMatch
       XCTAssertTrue(menu.waitForExistence(timeout:10));menu.tap();app.buttons["阅读设置"].firstMatch.tap()
       let picker=app.descendants(matching:.any).matching(identifier:"reader-readium-page-turn").firstMatch
       for _ in 0..<6 { if picker.exists && picker.isHittable {break};app.swipeUp() }
       XCTAssertTrue(picker.isHittable);picker.tap();app.buttons[title].firstMatch.tap()
       app.buttons["关闭"].firstMatch.tap()
       if title == "仿真翻页" {waitForCurl(app)}
       else {XCTAssertEqual(app.staticTexts["readium-validation-curl-state"].label,"idle")}
      }
      let initial=curlVisible(app),count=curlCounts(app)[1]
      app.coordinate(withNormalizedOffset:CGVector(dx:0.18,dy:0.17)).press(forDuration:0.8)
      let copy=app.buttons["拷贝"].firstMatch
      XCTAssertTrue(copy.waitForExistence(timeout:5) || app.menuItems["拷贝"].firstMatch.exists || app.buttons["Copy"].firstMatch.exists)
      XCTAssertEqual(curlVisible(app),initial);XCTAssertEqual(curlCounts(app)[1],count)
      let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Readium curl text selection";shot.lifetime = .keepAlways;add(shot)
     }
     func testReadiumCurlReopensCommittedPosition() {
      let app=openCurlBook();defer{app.terminate()}
      let initial=curlVisible(app)
      app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap()
      let changed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlVisible(app) != initial },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:20),.completed)
      waitForCurl(app)
      let saved=curlVisible(app);XCTAssertNotEqual(saved,initial);XCTAssertEqual(curlCounts(app)[1],1)
      app.terminate();app.launch()
      let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap();waitForCurl(app)
      XCTAssertEqual(curlVisible(app),saved);XCTAssertEqual(curlCounts(app)[1],0)
      sleep(2);XCTAssertEqual(curlVisible(app),saved)
     }
     func testReadiumCurlContinuityAndReturn() {
      let app=openCurlBook();defer{app.terminate()}
      var previous=curlVisible(app);XCTAssertEqual(previous.first,1)
      var count=0
      for backwards in [false,true] {
       for step in 0..<32 {
        if backwards ? previous.first == 1 : previous.last == 60 {break}
        if step % 2 == 0 { app.coordinate(withNormalizedOffset:CGVector(dx:backwards ? 0.15:0.85,dy:0.5)).tap() }
        else if backwards {app.swipeRight(velocity:.slow)} else {app.swipeLeft(velocity:.slow)}
        let changed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlVisible(app) != previous && !self.curlVisible(app).isEmpty },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:20),.completed, app.debugDescription)
        waitForCurl(app)
        let current=curlVisible(app)
        print("READIUM_CURL backwards=\(backwards) before=\(previous) after=\(current)")
        guard let first=current.first,let last=current.last,let oldFirst=previous.first,let oldLast=previous.last else{return}
        if backwards {XCTAssertGreaterThanOrEqual(last,oldFirst-1);XCTAssertLessThan(first,oldFirst)}
        else {XCTAssertLessThanOrEqual(first,oldLast+1);XCTAssertGreaterThan(last,oldLast)}
        previous=current;count += 1
        XCTAssertEqual(curlCounts(app)[1],count,"Each tap and swipe must complete the curl adapter")
       }
       XCTAssertEqual(backwards ? previous.first:previous.last,backwards ? 1:60)
      }
      XCTAssertGreaterThan(count,2)
      let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Readium卷页-跨章往返";shot.lifetime = .keepAlways;add(shot)
     }
'''
marker = '     func testReadiumMidChapterSwipesStayInChapter() {'
if source.count(marker) != 1:
    raise SystemExit('Pagination UI harness changed; update the Readium curl adapter')
source = source.replace(marker, methods + marker)
if '--epub-pagination' not in sys.argv:
    sys.argv.append('--epub-pagination')
if '--only-testing' not in sys.argv:
    sys.argv += ['--only-testing','TapTests/TapTests/testReadiumCurlPreparationDoesNotSaveProgress',
                 '--only-testing','TapTests/TapTests/testReadiumCurlContinuityAndReturn',
                 '--only-testing','TapTests/TapTests/testReadiumCurlCancellationAndRotation',
                 '--only-testing','TapTests/TapTests/testReadiumCurlStyleToggleAndSelection',
                 '--only-testing','TapTests/TapTests/testReadiumCurlReopensCommittedPosition',
                 '--only-testing','TapTests/TapTests/testReadiumCurlCancelsPreparationOnRotation']
namespace={'__name__':'__main__','__file__':str(base)}
exec(compile(source,str(base),'exec'),namespace)
# 只执行准备场景时，验证当前夹具没有新增任何精确或共享阅读位置。
if namespace['args'].only_testing == ['TapTests/TapTests/testReadiumCurlPreparationDoesNotSaveProgress']:
    import hashlib, json, plistlib
    root=namespace['data_root']
    digest=hashlib.sha256((root/'Library/Application Support/WenkuEPUB/pagination.epub').read_bytes()).hexdigest()
    prefs=root/'Library/Preferences/cc.novelia.ios.architecture-validation.plist'
    values=plistlib.loads(prefs.read_bytes()) if prefs.exists() else {}
    assert 'readium.locatorTime.v1.'+digest not in values, 'Snapshot preparation wrote an exact reading position'
    positions=json.loads(values.get('readingPositions.v1',b'{}'))
    assert 'epub:'+digest not in positions, 'Snapshot preparation wrote a shared reading position'
    print('Snapshot preparation preserved both exact and shared progress')
