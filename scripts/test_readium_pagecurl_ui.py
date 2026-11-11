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
      XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:30),.completed, "Curl preparation must settle: \(state.label) trace=\(app.staticTexts["readium-validation-curl-input"].label)\n\(app.debugDescription)")
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
     func measureCurlOpening(requireDeferred: Bool) {
      for sample in 0..<3 {
       let app=openCurlBook()
       let probe=app.staticTexts["readium-validation-curl-opening"]
       let measured=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !probe.label.contains("-1") },object:nil)
       XCTAssertEqual(XCTWaiter.wait(for:[measured],timeout:20),.completed)
       let times=probe.label.split(separator:",").compactMap{Int($0)}
       XCTAssertEqual(times.count,4)
       print("CURL_OPENING sample=\(sample) live_shadow_first_both_ms=\(probe.label)")
       if requireDeferred {
        XCTAssertLessThanOrEqual(times[0],times[1],"Prewarming must start after the real first page is presented")
        XCTAssertEqual(app.staticTexts["readium-validation-diagnostics"].label,"idle")
        XCTAssertLessThan(times[2],times[3],"First direction must become ready before both sides")
        XCTAssertEqual(Int(app.staticTexts["readium-validation-curl-live-snapshots"].label),1,"The current sheet must be captured from the live navigator only once")
       }
       app.terminate()
      }
     }
     func testReadiumCurlDirectionalAB() {
      for pair in 0..<3 {
       for serial in (pair % 2 == 0 ? [true,false] : [false,true]) {
        let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
        app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES"]
        if serial {app.launchArguments += ["-architectureCurlSerialBaseline"]}
        app.launch();let book=app.staticTexts["分页连续性"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout:20));book.tap();waitForCurl(app)
        let probe=app.staticTexts["readium-validation-curl-opening"]
        let measured=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !probe.label.contains("-1") },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[measured],timeout:20),.completed)
        let times=probe.label.split(separator:",").compactMap{Int($0)}
        XCTAssertEqual(times.count,4)
        XCTAssertLessThanOrEqual(times[0],times[1])
        if !serial {
         XCTAssertLessThan(times[2],times[3])
         XCTAssertEqual(Int(app.staticTexts["readium-validation-curl-live-snapshots"].label),1)
        }
        print("DIRECTIONAL_AB pair=\(pair) serial=\(serial) metrics=\(probe.label)")
        app.terminate()
       }
      }
     }
     func testReadiumDiagnosticsWaitsForTOC() {
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      defer{app.terminate()}
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES","-reader.showTOCDiagnostics","YES"]
      app.launch();let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap();waitForCurl(app)
      XCTAssertEqual(app.staticTexts["readium-validation-diagnostics"].label,"idle","Opening must not scan every resource")
      app.buttons["阅读菜单"].firstMatch.tap();app.buttons["目录"].firstMatch.tap()
      let probe=app.staticTexts["readium-validation-toc-diagnostics"]
      XCTAssertTrue(probe.waitForExistence(timeout:10))
      let done=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in probe.label == "done" },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[done],timeout:20),.completed,"Requested resource diagnostics must still run")
     }
     func testReadiumCurlOpeningTimingBaseline() {measureCurlOpening(requireDeferred:false)}
     func testReadiumCurlPrioritizesFirstPage() {measureCurlOpening(requireDeferred:true)}
     func testReadiumCurlTurnDuringOppositePreparation() {
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      defer{app.terminate()}
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES","-architectureCurlSlowOpposite"]
      app.launch();let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap();waitForCurl(app)
      XCTAssertEqual(app.staticTexts["readium-validation-curl-directions"].label,"1")
      app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap()
      let moved=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[moved],timeout:20),.completed);waitForCurl(app)
      let latency=Int(app.staticTexts["readium-validation-curl-performance"].label.split(separator:",")[0]) ?? 99999
      XCTAssertLessThan(latency,3000,"A turn toward the ready page must not wait for the injected 3-second opposite preparation")
      app.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.5)).tap()
      let returned=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 2 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[returned],timeout:20),.completed);waitForCurl(app)
     }
     func testReadiumCurlMissingReverseDirection() {
      let app=openCurlBook();defer{app.terminate()}
      app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap()
      let moved=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[moved],timeout:20),.completed);waitForCurl(app)
      XCTAssertGreaterThan(curlVisible(app).first ?? 0,1)
      app.terminate();app.launchArguments += ["-architectureCurlSlowOpposite"];app.launch()
      let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap();waitForCurl(app)
      XCTAssertEqual(app.staticTexts["readium-validation-curl-directions"].label,"1","Fixture must exercise an unprepared reverse direction")
      app.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.5)).tap()
      let returned=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 1 && self.curlVisible(app).first == 1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[returned],timeout:20),.completed,"First reverse tap must prepare and turn rather than report a boundary")
      waitForCurl(app)
     }
     func testReadiumCurlFirstInputDuringPreparation() {
      continueAfterFailure = false
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      defer{app.terminate()}
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES"]
      app.launch();let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap()
      XCTAssertTrue(app.staticTexts["readium-validation-curl-state"].waitForExistence(timeout:20))
      // 不等待快照ready，第一次中心点按就应隐藏控件；再次点按应恢复。
      let center=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
      center.tap()
      let menu=app.buttons["阅读菜单"].firstMatch
      let hidden=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !menu.exists },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[hidden],timeout:5),.completed)
      center.tap();XCTAssertTrue(menu.waitForExistence(timeout:5))
      let count=curlCounts(app)[1]
      app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5)).tap()
      let turned=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == count+1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[turned],timeout:20),.completed)
      waitForCurl(app)
      app.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.5)).tap()
      let returned=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == count+2 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[returned],timeout:20),.completed);waitForCurl(app)
     }
     func testReadiumCurlFirstSwipeDuringPreparation() {
      continueAfterFailure = false
      let app=XCUIApplication(bundleIdentifier:"cc.novelia.ios.architecture-validation")
      defer{app.terminate()}
      app.launchArguments=["-architectureValidation","-architectureReadium","-architecturePagination","-reader.readiumPageCurl.v1","YES"]
      app.launch();let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap()
      XCTAssertTrue(app.staticTexts["readium-validation-curl-state"].waitForExistence(timeout:20))
      app.swipeLeft(velocity:.slow)
      let turned=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[turned],timeout:20),.completed,"trace=\(app.staticTexts["readium-validation-curl-input"].label) counts=\(curlCounts(app)) visible=\(curlVisible(app)) state=\(app.staticTexts["readium-validation-curl-state"].label)\n\(app.debugDescription)");waitForCurl(app)
      app.swipeRight(velocity:.slow)
      let returned=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 2 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[returned],timeout:20),.completed);waitForCurl(app)
     }
     func testReadiumCurlQueuesNextInput() {
      let app=openCurlBook();defer{app.terminate()}
      let count=curlCounts(app)[1]
      let edge=app.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5))
      edge.tap();edge.tap();edge.tap()
      let three=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == count+3 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[three],timeout:30),.completed,"All three rapid taps must be honored")
      waitForCurl(app)
     }
     func testReadiumCurlRapidSwipes() {
      let app=openCurlBook();defer{app.terminate()}
      let count=curlCounts(app)[1]
      app.swipeLeft(velocity:.fast)
      app.swipeLeft(velocity:.fast)
      app.swipeLeft(velocity:.fast)
      let three=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == count+3 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[three],timeout:30),.completed,"Three rapid swipes must all be honored; burst=\(app.staticTexts["readium-validation-curl-burst"].label) trace=\(app.staticTexts["readium-validation-curl-input"].label)")
      waitForCurl(app)
      let burst=app.staticTexts["readium-validation-curl-burst"].label.split(separator:",").compactMap{Int($0)}
      XCTAssertEqual(burst.last,0,"Animation-window input must not be dropped")
      if burst.count == 2 {
       print("CURL_BURST between_turns_ms=\(burst[0])")
       XCTAssertLessThan(burst[0],200,"Queued turns must start without waiting for the commit")
      }
     }
     func testReadiumCurlBurstRotation() {
      continueAfterFailure=false
      let app=openCurlBook();defer{XCUIDevice.shared.orientation = .portrait;app.terminate()}
      let count=curlCounts(app)[1]
      app.swipeLeft(velocity:.fast);app.swipeLeft(velocity:.fast);app.swipeLeft(velocity:.fast)
      XCUIDevice.shared.orientation = .landscapeLeft
      sleep(2);waitForCurl(app)
      XCUIDevice.shared.orientation = .portrait
      sleep(2);waitForCurl(app)
      let committed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] >= count+1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[committed],timeout:10),.completed,"Burst rotation must commit the shown page")
      XCTAssertNotEqual(app.staticTexts["readium-validation-curl-state"].label,"busy")
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
      let both=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.staticTexts["readium-validation-curl-directions"].label == "3" },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[both],timeout:20),.completed)
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
      let saved=curlVisible(app);XCTAssertNotEqual(saved,initial)
      let committed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == 1 },object:nil)
      XCTAssertEqual(XCTWaiter.wait(for:[committed],timeout:5),.completed,"Landed page must commit before reopening")
      app.terminate();app.launch()
      let book=app.staticTexts["分页连续性"].firstMatch
      XCTAssertTrue(book.waitForExistence(timeout:20));book.tap();waitForCurl(app)
      XCTAssertEqual(curlVisible(app),saved);XCTAssertEqual(curlCounts(app)[1],0)
      sleep(2);XCTAssertEqual(curlVisible(app),saved)
     }
     func testReadiumCurlTurnReadinessTiming() {
      let app=openCurlBook();defer{app.terminate()}
      let initial=curlVisible(app)
      var previous=initial
      let preparations=curlCounts(app)[0]
      for backwards in [false,true] {
       for _ in 0..<4 {
        sleep(1)
        app.coordinate(withNormalizedOffset:CGVector(dx:backwards ? 0.15:0.85,dy:0.5)).tap()
        let changed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlVisible(app) != previous },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:20),.completed)
        waitForCurl(app)
        previous=curlVisible(app)
        XCTAssertEqual(curlCounts(app)[0],preparations,"Warm turns must reuse prepared pages without foreground preparation")
        print("CURL_TIMING backwards=\(backwards) metric=\(app.staticTexts["readium-validation-curl-performance"].label) preparations=\(self.curlCounts(app)[0])")
       }
      }
      XCTAssertEqual(previous,initial)
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
        let committed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in self.curlCounts(app)[1] == count },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[committed],timeout:5),.completed,"Each tap and swipe must commit the curl adapter")
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
                 '--only-testing','TapTests/TapTests/testReadiumCurlCancelsPreparationOnRotation',
                 '--only-testing','TapTests/TapTests/testReadiumCurlTurnReadinessTiming',
                 '--only-testing','TapTests/TapTests/testReadiumCurlFirstInputDuringPreparation',
                 '--only-testing','TapTests/TapTests/testReadiumCurlFirstSwipeDuringPreparation',
                 '--only-testing','TapTests/TapTests/testReadiumCurlQueuesNextInput',
                 '--only-testing','TapTests/TapTests/testReadiumCurlRapidSwipes',
                 '--only-testing','TapTests/TapTests/testReadiumCurlBurstRotation',
                 '--only-testing','TapTests/TapTests/testReadiumCurlPrioritizesFirstPage',
                 '--only-testing','TapTests/TapTests/testReadiumDiagnosticsWaitsForTOC',
                 '--only-testing','TapTests/TapTests/testReadiumCurlMissingReverseDirection',
                 '--only-testing','TapTests/TapTests/testReadiumCurlTurnDuringOppositePreparation']
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
