#!/usr/bin/env python3
"""人物卡详情页 UI 回归：种入“林舟”完整数据，导航到卡片并截图供参考图对照。"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--app', required=True, help='Built dedicated architecture-validation Novelia.app')
parser.add_argument('--shots', type=Path, help='Directory for exported screenshots')
args = parser.parse_args()
r = Path(tempfile.mkdtemp(prefix='NoveliaCharacterCardUI-'))
subprocess.run(['xcrun', 'simctl', 'boot', args.device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(['xcrun', 'simctl', 'bootstatus', args.device, '-b'], check=True)
subprocess.run(['xcrun', 'simctl', 'install', args.device, args.app], check=True)
(r / 'TapRegression.swift').write_text('import SwiftUI\n@main struct TapRegressionApp: App { var body: some Scene { WindowGroup { Text("Character card UI runner") } } }\n')
(r / 'TapTests.swift').write_text('''import XCTest
final class TapTests: XCTestCase {
 func shot(_ name: String) {
  let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
  attachment.name = name
  attachment.lifetime = .keepAlways
  add(attachment)
 }
 func testCharacterCardLayout() {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: "cc.novelia.ios.architecture-validation")
  app.launchArguments = ["-architectureValidation", "-resetArchitectureValidation", "-architectureTXT", "-architectureCharacterPortrait"]
  app.launch(); defer { app.terminate() }
  XCTAssertTrue(app.tabBars.buttons["\\u{4e66}\\u{5e93}"].waitForExistence(timeout: 30))
  app.tabBars.buttons["\\u{4e66}\\u{5e93}"].tap()
  let segment = app.segmentedControls.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\\u{7cfb}\\u{5217}")).firstMatch
  XCTAssertTrue(segment.waitForExistence(timeout: 20)); segment.tap()
  let series = app.staticTexts["\\u{96fe}\\u{6e2f}\\u{6765}\\u{4fe1}"].firstMatch
  XCTAssertTrue(series.waitForExistence(timeout: 20)); series.tap()
  let menu = app.buttons["\\u{7cfb}\\u{5217}\\u{64cd}\\u{4f5c}"].firstMatch
  XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
  let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "AI \\u{4eba}\\u{7269}\\u{8bcd}\\u{6761}")).firstMatch
  XCTAssertTrue(entry.waitForExistence(timeout: 20)); entry.tap()
  // 人物卡分区在 List 底部，懒加载行需滚动后才存在。
  var row = app.staticTexts["\\u{6797}\\u{821f}"].firstMatch
  for _ in 0..<6 {
   if row.exists && row.isHittable { break }
   app.swipeUp()
  }
  if !row.waitForExistence(timeout: 15) {
   shot("characters-page-stuck")
   XCTFail("人物卡列表应在滚动后出现林舟；页面内容见截图")
  }
  row.tap()
  XCTAssertTrue(app.staticTexts["\\u{4eba}\\u{7269}\\u{6863}\\u{6848}"].waitForExistence(timeout: 30), "卡片应显示人物档案面板")
  XCTAssertTrue(app.staticTexts["\\u{4eba}\\u{7269}\\u{5173}\\u{7cfb}"].exists)
  XCTAssertTrue(app.staticTexts["\\u{91cd}\\u{8981}\\u{7ecf}\\u{5386}"].exists)
  sleep(2)
  shot("character-card-top")
  app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\\u{5f85}\\u{6838}\\u{5b9e}")).firstMatch.tap()
  app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\\u{51fa}\\u{5904} \\u{00b7}")).firstMatch.tap()
  sleep(1)
  shot("character-card-expanded")
  app.swipeUp()
  shot("character-card-bottom")
 }
 func testStandaloneBookCharacterEntry() {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: "cc.novelia.ios.architecture-validation")
  app.launchArguments = ["-architectureValidation", "-resetArchitectureValidation", "-architectureTXT",
                         "-architectureCharacterPortrait", "-architectureCharacterStandalone"]
  app.launch(); defer { app.terminate() }
  XCTAssertTrue(app.tabBars.buttons["\\u{4e66}\\u{5e93}"].waitForExistence(timeout: 30))
  app.tabBars.buttons["\\u{4e66}\\u{5e93}"].tap()
  let more = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\\u{66f4}\\u{591a}\\u{64cd}\\u{4f5c}\\u{ff1a}\\u{67b6}\\u{6784}\\u{9a8c}\\u{8bc1}TXT")).firstMatch
  XCTAssertTrue(more.waitForExistence(timeout: 20), "未分组书行应提供更多菜单")
  more.tap()
  let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "AI \\u{4eba}\\u{7269}\\u{8bcd}\\u{6761}")).firstMatch
  XCTAssertTrue(entry.waitForExistence(timeout: 20), "更多菜单应有 AI 人物词条直达入口")
  entry.tap()
  var row = app.staticTexts["\\u{6797}\\u{821f}"].firstMatch
  for _ in 0..<6 {
   if row.exists && row.isHittable { break }
   app.swipeUp()
  }
  if !row.waitForExistence(timeout: 15) {
   shot("standalone-characters-stuck")
   XCTFail("未入系列的书应能通过直达入口看到人物卡；页面内容见截图")
  }
  row.tap()
  XCTAssertTrue(app.staticTexts["\\u{4eba}\\u{7269}\\u{6863}\\u{6848}"].waitForExistence(timeout: 30), "单书直达的卡片应显示人物档案面板")
  sleep(2)
  shot("standalone-character-card")
 }
 func testReaderMenuCharacterCards() {
  continueAfterFailure = false
  let app = XCUIApplication(bundleIdentifier: "cc.novelia.ios.architecture-validation")
  app.launchArguments = ["-architectureValidation", "-resetArchitectureValidation", "-architectureTXT",
                         "-architectureCharacterPortrait", "-architectureCharacterStandalone"]
  app.launch(); defer { app.terminate() }
  XCTAssertTrue(app.tabBars.buttons["\\u{4e66}\\u{5e93}"].waitForExistence(timeout: 30))
  app.tabBars.buttons["\\u{4e66}\\u{5e93}"].tap()
  let book = app.staticTexts["\\u{67b6}\\u{6784}\\u{9a8c}\\u{8bc1}TXT"].firstMatch
  XCTAssertTrue(book.waitForExistence(timeout: 20)); book.tap()
  let readerMenu = app.buttons["\\u{9605}\\u{8bfb}\\u{83dc}\\u{5355}"].firstMatch
  XCTAssertTrue(readerMenu.waitForExistence(timeout: 30), "阅读器右上角应有阅读菜单")
  readerMenu.tap()
  let aiMenu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "AI \\u{9605}\\u{8bfb}\\u{8f85}\\u{52a9}")).firstMatch
  XCTAssertTrue(aiMenu.waitForExistence(timeout: 20)); aiMenu.tap()
  let cards = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "\\u{67e5}\\u{770b}\\u{89d2}\\u{8272}\\u{5361}")).firstMatch
  XCTAssertTrue(cards.waitForExistence(timeout: 20), "AI 阅读辅助二级菜单应有查看角色卡")
  cards.tap()
  var row = app.staticTexts["\\u{6797}\\u{821f}"].firstMatch
  for _ in 0..<6 {
   if row.exists && row.isHittable { break }
   app.swipeUp()
  }
  if !row.waitForExistence(timeout: 15) {
   shot("reader-cards-stuck")
   XCTFail("书内查看角色卡应显示人物卡列表；页面内容见截图")
  }
  row.tap()
  XCTAssertTrue(app.staticTexts["\\u{4eba}\\u{7269}\\u{6863}\\u{6848}"].waitForExistence(timeout: 30), "书内打开的卡片应显示人物档案面板")
  sleep(2)
  shot("reader-character-card")
 }
}
''')
def ID(n): return f'A{n:023X}'
objects = []
def obj(n, txt): objects.append(ID(n) + ' = {' + txt + '};')
obj(1, f'isa=PBXProject; buildConfigurationList={ID(20)}; compatibilityVersion="Xcode 14.0"; mainGroup={ID(2)}; productRefGroup={ID(3)}; projectDirPath=""; projectRoot=""; targets=({ID(10)},{ID(11)});')
obj(2, f'isa=PBXGroup; children=({ID(4)},{ID(5)},{ID(3)}); sourceTree="<group>";')
obj(3, f'isa=PBXGroup; name=Products; children=({ID(6)},{ID(7)}); sourceTree="<group>";')
obj(4, 'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path=TapRegression.swift; sourceTree="<group>";')
obj(5, 'isa=PBXFileReference; lastKnownFileType=sourcecode.swift; path=TapTests.swift; sourceTree="<group>";')
obj(6, 'isa=PBXFileReference; explicitFileType=wrapper.application; path=TapRegression.app; sourceTree=BUILT_PRODUCTS_DIR;')
obj(7, 'isa=PBXFileReference; explicitFileType=wrapper.cfbundle; path=TapTests.xctest; sourceTree=BUILT_PRODUCTS_DIR;')
obj(8, f'isa=PBXBuildFile; fileRef={ID(4)};'); obj(9, f'isa=PBXBuildFile; fileRef={ID(5)};')
obj(10, f'isa=PBXNativeTarget; name=TapRegression; productName=TapRegression; productReference={ID(6)}; productType="com.apple.product-type.application"; buildConfigurationList={ID(21)}; buildPhases=({ID(12)}); dependencies=();')
obj(11, f'isa=PBXNativeTarget; name=TapTests; productName=TapTests; productReference={ID(7)}; productType="com.apple.product-type.bundle.ui-testing"; buildConfigurationList={ID(22)}; buildPhases=({ID(13)}); dependencies=({ID(15)});')
obj(12, f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({ID(8)}); runOnlyForDeploymentPostprocessing=0;'); obj(13, f'isa=PBXSourcesBuildPhase; buildActionMask=2147483647; files=({ID(9)}); runOnlyForDeploymentPostprocessing=0;')
obj(14, f'isa=PBXContainerItemProxy; containerPortal={ID(1)}; proxyType=1; remoteGlobalIDString={ID(10)}; remoteInfo=TapRegression;')
obj(15, f'isa=PBXTargetDependency; target={ID(10)}; targetProxy={ID(14)};')
settings = 'SWIFT_VERSION=5.0; SDKROOT=iphonesimulator; IPHONEOS_DEPLOYMENT_TARGET=17.0; CODE_SIGNING_ALLOWED=NO; GENERATE_INFOPLIST_FILE=YES; TARGETED_DEVICE_FAMILY=1; PRODUCT_NAME="$(TARGET_NAME)";'
for n, extra in [(30, ''), (31, 'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.character-card-regression"; INFOPLIST_KEY_UILaunchScreen_Generation=YES;'), (32, 'PRODUCT_BUNDLE_IDENTIFIER="cc.novelia.character-card-regression.tests"; TEST_TARGET_NAME=TapRegression;')]: obj(n, 'isa=XCBuildConfiguration; name=Debug; buildSettings={' + settings + extra + '};')
for n, c in [(20, 30), (21, 31), (22, 32)]: obj(n, f'isa=XCConfigurationList; buildConfigurations=({ID(c)}); defaultConfigurationIsVisible=0; defaultConfigurationName=Debug;')
p = r / 'TapRegression.xcodeproj'; p.mkdir(exist_ok=True); (p / 'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1; classes={}; objectVersion=56; objects={' + ''.join(objects) + '}; rootObject=' + ID(1) + ';}')
d = p / 'xcshareddata/xcschemes'; d.mkdir(parents=True, exist_ok=True)
def ref(n, name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ID(n)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:TapRegression.xcodeproj"/>'
(d / 'TapTests.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.3"><BuildAction parallelizeBuildables="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">' + ref(10, 'TapRegression.app') + '</BuildActionEntry><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">' + ref(11, 'TapTests.xctest') + '</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">' + ref(11, 'TapTests.xctest') + '</TestableReference></Testables></TestAction></Scheme>')
result = r / 'result.xcresult'
print(f'UI test artifacts: {r}', flush=True)
with (r / 'test.log').open('w') as log:
    subprocess.run(['xcodebuild', '-project', str(p), '-scheme', 'TapTests', '-destination', f'platform=iOS Simulator,id={args.device}',
                    '-derivedDataPath', str(r / 'DerivedData'), '-parallel-testing-enabled', 'NO',
                    '-resultBundlePath', str(result), 'test'], stdout=log, stderr=subprocess.STDOUT, check=True)
shots = args.shots or (r / 'shots')
shots.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(shots)], check=True)
print(f'Character card screenshots exported to {shots}')
