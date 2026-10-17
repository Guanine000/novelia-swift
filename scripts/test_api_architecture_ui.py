#!/usr/bin/env python3
"""Run real RootView/features against a complete replacement in a dedicated App bundle."""
from pathlib import Path
import argparse
import subprocess
import tempfile
import json
import hashlib
import plistlib
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--app', required=True, help='Built dedicated architecture-validation Novelia.app')
parser.add_argument('--only-testing', help='Run one UI regression after a targeted change')
parser.add_argument('--performance', action='store_true', help='Record simulator Debug baseline metrics instead of functional UI regressions')
parser.add_argument('--library-count', type=int, choices=[0, 300, 3000], default=300)
parser.add_argument('--iterations', type=int, choices=range(2, 11), default=3)
parser.add_argument('--result-json', type=Path)
args = parser.parse_args()
r = Path(tempfile.mkdtemp(prefix='NoveliaArchitectureUI-'))
# Boot only the selected simulator; the installed App has its own bundle/data.
subprocess.run(['xcrun','simctl','boot',args.device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(['xcrun','simctl','bootstatus',args.device,'-b'], check=True)
subprocess.run(['xcrun','simctl','install',args.device,args.app], check=True)
(r/'TapRegression.swift').write_text('import SwiftUI\n@main struct TapRegressionApp: App { var body: some Scene { WindowGroup { Text("Architecture UI runner") } } }\n')
(r/'TapTests.swift').write_text(r'''import XCTest
final class TapTests: XCTestCase {
 let bundle = "cc.novelia.ios.architecture-validation"
 func start(readium: Bool = false, failSearch: Bool = false, txt: Bool = false) -> XCUIApplication {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: bundle)
  app.launchArguments = ["-architectureValidation", "-resetArchitectureValidation"]
  if txt { app.launchArguments.append("-architectureTXT") }
  if failSearch { app.launchArguments.append("-architectureFailFirstSearch") }
  if readium { app.launchArguments.append("-architectureReadium") }
  app.launch()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].waitForExistence(timeout: 15))
  return app
 }
 func reveal(_ element: XCUIElement, app: XCUIApplication, up: Bool = true) {
  for _ in 0..<8 {
   if element.exists && element.isHittable { return }
   if up { app.swipeUp() } else { app.swipeDown() }
  }
  XCTAssertTrue(element.exists && element.isHittable, "Control is not reachable: \(element)")
 }
 func zeroExternalRequests(_ app: XCUIApplication) {
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].label.contains("\u{5916}\u{90e8}\u{8bf7}\u{6c42} 0"))
 }
 func openNovel(_ app: XCUIApplication) {
  app.tabBars.buttons["\u{53d1}\u{73b0}"].tap()
  let book = app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5c0f}\u{8bf4}"].firstMatch
  XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
  XCTAssertTrue(app.navigationBars["\u{4f5c}\u{54c1}\u{8be6}\u{60c5}"].waitForExistence(timeout: 10))
 }
 func testDiscoveryCommentsDownloadAndLibrary() {
  let app = start(); defer { app.terminate() }
  openNovel(app)
  let comments = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\u{8bc4}\u{8bba}\u{533a}")).firstMatch
  reveal(comments, app: app); comments.tap()
  XCTAssertTrue(app.navigationBars["\u{8bc4}\u{8bba}\u{533a}"].waitForExistence(timeout: 10))
  let editor = app.textViews.firstMatch
  XCTAssertTrue(editor.waitForExistence(timeout: 10)); reveal(editor, app: app); editor.tap()
  editor.typeText("architecture-validation-comment")
  app.buttons["\u{53d1}\u{9001}"].tap()
  XCTAssertTrue(app.staticTexts["architecture-validation-comment"].firstMatch.waitForExistence(timeout: 10))
  app.navigationBars.buttons.element(boundBy: 0).tap()
  let download = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\u{4e0b}\u{8f7d}\u{5168}\u{4e66} EPUB")).firstMatch
  reveal(download, app: app, up: false); download.tap()
  XCTAssertTrue(app.navigationBars["\u{4e0b}\u{8f7d}\u{5168}\u{4e66}"].waitForExistence(timeout: 10))
  let begin = app.buttons["\u{5f00}\u{59cb}\u{4e0b}\u{8f7d}"]; reveal(begin, app: app); begin.tap()
  let completed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "EPUB \u{4e0b}\u{8f7d}\u{5b8c}\u{6210}")).firstMatch
  XCTAssertTrue(completed.waitForExistence(timeout: 30))
  app.buttons["\u{5173}\u{95ed}"].tap()
  app.navigationBars.buttons.element(boundBy: 0).tap()
  app.tabBars.buttons["\u{4e66}\u{5e93}"].tap()
  XCTAssertTrue(app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5c0f}\u{8bf4}"].firstMatch.waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
 func testCommunityUsesReplacementPostAndReplies() {
  let app = start(); defer { app.terminate() }
  app.tabBars.buttons["\u{793e}\u{533a}"].tap()
  let post = app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5e16}\u{5b50}"].firstMatch
  XCTAssertTrue(post.waitForExistence(timeout: 15)); post.tap()
  XCTAssertTrue(app.staticTexts["\u{8fd9}\u{662f}\u{66ff}\u{4ee3}\u{670d}\u{52a1}\u{63d0}\u{4f9b}\u{7684}\u{5e16}\u{5b50}\u{6b63}\u{6587}\u{3002}"].firstMatch.waitForExistence(timeout: 10))
  zeroExternalRequests(app)
 }
 func testReadiumOnlineChapterFromReplacement() {
  let app = start(readium: true); defer { app.terminate() }
  openNovel(app)
  let read = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\u{7ee7}\u{7eed}\u{9605}\u{8bfb}")).firstMatch
  reveal(read, app: app); read.tap()
  XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
  let body = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\u{7ae0}\u{8282}\u{83b7}\u{53d6}\u{4e0d}\u{7ecf}\u{8fc7}\u{771f}\u{5b9e}\u{670d}\u{52a1}\u{5668}")).firstMatch
  XCTAssertTrue(body.waitForExistence(timeout: 30), "Readium must display replacement chapter text")
  zeroExternalRequests(app)
 }
 func testReplacementFailureAndRetry() {
  let app = start(failSearch: true); defer { app.terminate() }
  app.tabBars.buttons["\u{53d1}\u{73b0}"].tap()
  let retry = app.buttons["\u{91cd}\u{8bd5}"].firstMatch
  XCTAssertTrue(retry.waitForExistence(timeout: 15)); retry.tap()
  XCTAssertTrue(app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}\u{5c0f}\u{8bf4}"].firstMatch.waitForExistence(timeout: 15))
  zeroExternalRequests(app)
 }
 func testReadiumTXTWithIsolatedLocalLibrary() {
  let app = start(readium: true, txt: true); defer { app.terminate() }
  let book = app.staticTexts["\u{67b6}\u{6784}\u{9a8c}\u{8bc1}TXT"].firstMatch
  XCTAssertTrue(book.waitForExistence(timeout: 15)); book.tap()
  XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
  let body = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\u{672c}\u{5730}TXT\u{9a8c}\u{8bc1}\u{6b63}\u{6587}")).firstMatch
  XCTAssertTrue(body.waitForExistence(timeout: 30))
  zeroExternalRequests(app)
 }
}
''', encoding='utf-8')
if args.performance:
    performance = r'''import XCTest
final class TapTests: XCTestCase {
 static var seeded = false
 let bundle = "cc.novelia.ios.architecture-validation"
 func configured() -> XCUIApplication {
  let app = XCUIApplication(bundleIdentifier: bundle)
  app.launchArguments = ["-architectureValidation"]
  return app
 }
 func seed(large: Bool = false) {
  let app = configured()
  app.launchArguments += ["-resetArchitectureValidation", "-seedPerformanceLibrary", "-performanceLibraryCount", "LIBRARY_COUNT"]
  if large { app.launchArguments.append("-performanceLargeTXT") }
  app.launch()
  XCTAssertTrue(app.staticTexts["architecture-validation-status"].waitForExistence(timeout: 60))
  app.terminate()
 }
 override func setUpWithError() throws {
  continueAfterFailure = false
  if !Self.seeded { seed(); Self.seeded = true }
 }
 func options() -> XCTMeasureOptions {
  let options = XCTMeasureOptions(); options.iterationCount = ITERATIONS; return options
 }
 func testALaunch() {
  let app = configured()
  measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options()) {
   app.launch(); app.terminate()
  }
 }
 func testBScroll() throws {
  if LIBRARY_COUNT == 0 { throw XCTSkip("Empty library has no scrolling workload") }
  let app = configured(); app.launch(); defer { app.terminate() }
  let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-book-")).firstMatch
  XCTAssertTrue(row.waitForExistence(timeout: 30))
  measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
                    XCTOSSignpostMetric.scrollDecelerationMetric], options: options()) {
   app.swipeUp(); app.swipeDown()
  }
 }
 func testCLaunchAndOpenLargeTXT() {
  seed(large: true)
  let app = configured()
  measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app)], options: options()) {
   app.launch()
   let book = app.staticTexts["基准长 TXT"].firstMatch
   XCTAssertTrue(book.waitForExistence(timeout: 30)); book.tap()
   let body = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "性能基准正文")).firstMatch
   XCTAssertTrue(body.waitForExistence(timeout: 60))
   app.terminate()
  }
 }
 func waitForEPUB(_ app: XCUIApplication) {
  let next = app.buttons["下一页"]
  XCTAssertTrue(next.waitForExistence(timeout: 30))
  let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
  XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed)
 }
 func testDLaunchAndOpenSampleEPUB() {
  let app = configured(); app.launchArguments.append("-openEPUBPrototype")
  // 样例文件生成不计时；测量后续进程启动至分页可操作，默认 Yuedu 引擎。
  app.launch(); waitForEPUB(app); app.terminate()
  measure(metrics: [XCTClockMetric()], options: options()) {
   app.launch(); waitForEPUB(app); app.terminate()
  }
 }
}
'''.replace('LIBRARY_COUNT', str(args.library_count)).replace('ITERATIONS', str(args.iterations))
    (r/'TapTests.swift').write_text(performance)
def ID(n):return f'A{n:023X}'
objects=[]
def obj(n,txt):objects.append(ID(n)+' = {'+txt+'};')
obj(1,f'isa=PBXProject; buildConfigurationList={ID(20)}; compatibilityVersion="Xcode 14.0"; mainGroup={ID(2)}; productRefGroup={ID(3)}; projectDirPath=""; projectRoot=""; targets=({ID(10)},{ID(11)});')
obj(2,f'isa=PBXGroup; children=({ID(4)},{ID(5)},{ID(3)}); sourceTree="<group>";')
obj(3,f'isa=PBXGroup; name=Products; children=({ID(6)},{ID(7)}); sourceTree="<group>";')
obj(4,'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path=TapRegression.swift; sourceTree="<group>";')
obj(5,'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path=TapTests.swift; sourceTree="<group>";')
obj(6,'isa=PBXFileReference; explicitFileType=wrapper.application; path=TapRegression.app; sourceTree=BUILT_PRODUCTS_DIR;')
obj(7,'isa=PBXFileReference; explicitFileType=wrapper.cfbundle; path=TapTests.xctest; sourceTree=BUILT_PRODUCTS_DIR;')
obj(8,f'isa=PBXBuildFile; fileRef={ID(4)};');obj(9,f'isa=PBXBuildFile; fileRef={ID(5)};')
obj(10,f'isa=PBXNativeTarget; name=TapRegression; productName=TapRegression; productReference={ID(6)}; productType="com.apple.product-type.application"; buildConfigurationList={ID(21)}; buildPhases=({ID(12)}); dependencies=();')
obj(11,f'isa=PBXNativeTarget; name=TapTests; productName=TapTests; productReference={ID(7)}; productType="com.apple.product-type.bundle.ui-testing"; buildConfigurationList={ID(22)}; buildPhases=({ID(13)}); dependencies=({ID(15)});')
obj(12,f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({ID(8)}); runOnlyForDeploymentPostprocessing=0;');obj(13,f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({ID(9)}); runOnlyForDeploymentPostprocessing=0;')
obj(14,f'isa=PBXContainerItemProxy; containerPortal={ID(1)}; proxyType=1; remoteGlobalIDString={ID(10)}; remoteInfo=TapRegression;')
obj(15,f'isa=PBXTargetDependency; target={ID(10)}; targetProxy={ID(14)};')
settings='SWIFT_VERSION=5.0; SDKROOT=iphonesimulator; IPHONEOS_DEPLOYMENT_TARGET=17.0; CODE_SIGNING_ALLOWED=NO; GENERATE_INFOPLIST_FILE=YES; TARGETED_DEVICE_FAMILY=1; PRODUCT_NAME="$(TARGET_NAME)";'
for n,extra in [(30,''),(31,'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.library-regression"; INFOPLIST_KEY_UILaunchScreen_Generation=YES;'),(32,'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.library-regression.tests"; TEST_TARGET_NAME=TapRegression;')]:obj(n,'isa=XCBuildConfiguration; name=Debug; buildSettings={'+settings+extra+'};')
for n,c in [(20,30),(21,31),(22,32)]:obj(n,f'isa=XCConfigurationList; buildConfigurations=({ID(c)}); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;')
p=r/'TapRegression.xcodeproj';p.mkdir(exist_ok=True);(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={'+''.join(objects)+'}; rootObject='+ID(1)+';}')
d=p/'xcshareddata/xcschemes';d.mkdir(parents=True,exist_ok=True)
def ref(n,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ID(n)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:TapRegression.xcodeproj"/>'
(d/'TapTests.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.3"><BuildAction parallelizeBuildables="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">'+ref(10,'TapRegression.app')+'</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">'+ref(11,'TapTests.xctest')+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+ref(11,'TapTests.xctest')+'</TestableReference></Testables></TestAction></Scheme>')
print(f'UI test artifacts: {r}', flush=True)
with (r / 'test.log').open('w') as log:
 subprocess.run(['xcodebuild','-project',str(p),'-scheme','TapTests','-destination',f'platform=iOS Simulator,id={args.device}','-derivedDataPath',str(r/'DerivedData'),'-parallel-testing-enabled','NO','test'] + ([f'-only-testing:{args.only_testing}'] if args.only_testing else []),stdout=log,stderr=subprocess.STDOUT,check=True)
if args.performance:
    metrics = subprocess.run(['xcrun','xcresulttool','get','test-results','metrics','--path',
                              str(next((r/'DerivedData/Logs/Test').glob('*.xcresult'))), '--compact'],
                             capture_output=True, text=True)
    root = Path(__file__).resolve().parents[1]
    digest = hashlib.sha256()
    for source in sorted([* (root/'Sources').rglob('*.swift'), * (root/'iOSApp').rglob('*.swift')]):
        digest.update(str(source.relative_to(root)).encode()); digest.update(source.read_bytes())
    info = plistlib.loads((Path(args.app)/'Info.plist').read_bytes())
    report = {'scope':'simulator_debug_ui_baseline', 'library_count':args.library_count,
              'iterations':args.iterations, 'source_sha256':digest.hexdigest(),
              'version':info.get('CFBundleShortVersionString'), 'build':info.get('CFBundleVersion'),
              'app_executable_sha256':hashlib.sha256((Path(args.app)/info['CFBundleExecutable']).read_bytes()).hexdigest(),
              'artifacts':str(r), 'device_id':args.device,
              'xcode_version':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
              'sdk':info.get('DTSDKName'),
              'limitations':['synthetic data and replacement backend','Debug build','not physical device or battery qualification',
                             'large TXT metric includes app launch and UI automation; no pass/fail performance thresholds']}
    if metrics.returncode == 0:
        report['metrics'] = json.loads(metrics.stdout)
    else:
        report['metrics_export_error'] = metrics.stderr[:1000]
    if args.result_json:
        args.result_json.parent.mkdir(parents=True, exist_ok=True)
        args.result_json.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False, indent=2))
else:
    print('Actual App replacement-service UI flows passed')
